# frozen_string_literal: true

# Two-way sync demo. Needs the prototype running (bin/setup, then bin/start).
#
#   bundle exec ruby prototype/site_sync/demo/run.rb            # every scene
#   bundle exec ruby prototype/site_sync/demo/run.rb offline    # one scene
#
# Every scene changes data the way a clinic would (the real MaHIS API, or SQL
# where the point is to simulate a fault), then checks the outcome on all
# three databases.
require_relative 'harness'
include Demo # rubocop:disable Style/MixinUsage

$stdout.sync = true

SCENES = {}
SHARED = {}

def scene(name, heading, &block)
  SCENES[name] = [heading, block]
end

# MaHIS rejects names with digits, so make names unique with letters.
def unique_letters
  Array.new(4) { ('a'..'z').to_a.sample }.join
end

def admin_person_id(node)
  value(node, "SELECT person_id FROM users WHERE username = 'admin'")
end

def with_agent_stopped(site)
  sh("#{PROTO}/bin/stop agent_#{site}", quiet: true)
  yield
ensure
  sh("#{PROTO}/bin/start agents", quiet: true)
end

# ---------------------------------------------------------------------------
scene 'live', '1. Live sync: a patient registered at Site A reaches central' do
  step 'Register a patient at Site A (POST /api/v1/people, POST /api/v1/patients)'
  patient = register_patient(:a, given: 'Thoko', family: "Phiri#{unique_letters}")
  info "Site A person_id #{patient[:person_id]}, uuid #{patient[:uuid]}"

  step 'Record a weight (POST /api/v1/encounters with one observation)'
  visit = record_weight(:a, patient[:person_id], 61.5)
  seconds = wait_for('patient and visit at central') do
    at_central?('person', patient[:uuid]) && at_central?('encounter', visit[:uuid])
  end
  measure 'lag Site A -> central (demo push interval 2 s)', "#{seconds} s"

  check('patient is at central') { at_central?('person', patient[:uuid]) }
  check('visit and weight are at central') do
    value(:central, "SELECT o.value_numeric FROM obs o JOIN encounter e ON e.encounter_id = o.encounter_id
                     WHERE e.uuid = '#{visit[:uuid]}'").to_f == 61.5
  end
  info "central gave the patient its own id #{person_id(:central, patient[:uuid])} " \
       "(Site A: #{patient[:person_id]}); they are matched by uuid"

  step 'Which rows did that one API call create? (endpoint tracking)'
  _, body, = api(:a, :get, "/api/v1/site_sync/requests/#{visit[:request_id]}")
  body['changes'].each do |c|
    info "#{c['table_name'].ljust(10)} #{c['op']}  #{c['row_uuid']}  #{c['endpoint']}  -> " \
         "#{c['lane']} batch ##{c['batch_seq']} (#{c['sync_status']})"
  end
  check('each change carries its endpoint and user') do
    body['changes'].any? && body['changes'].all? { |c| c['endpoint'] == 'POST /api/v1/encounters' && c['user_uuid'] }
  end
  SHARED[:patient_a] = patient
end

# ---------------------------------------------------------------------------
scene 'offline', '2. Site A offline: work continues, the queue drains in order' do
  step 'Cut Site A off from central'
  link('A', 'cut')
  patients = %w[Chikondi Mphatso Tiyamike].map { |given| register_patient(:a, given:, family: "Kumwenda#{unique_letters}") }
  info "registered #{patients.size} patients while offline; Site A has #{unsent(:a)} changes waiting"
  sleep 5
  check('nothing reached central while offline') { patients.none? { |p| at_central?('person', p[:uuid]) } }
  check('changes are kept safely in the Site A queue') { unsent(:a).positive? }

  step 'Restore the link'
  link('A', 'restore')
  seconds = wait_for('queue drained', timeout: 90) { patients.all? { |p| at_central?('person', p[:uuid]) } }
  info "queue drained #{seconds} s after the link came back (agent backs off while offline, max 10 s in the demo)"
  check('all patients registered offline are at central') { patients.all? { |p| at_central?('person', p[:uuid]) } }
  check('no gaps: every batch number arrived exactly once, in order') do
    rows(:central, <<~SQL).all? { |r| r['committed_seq'].to_i == r['received'].to_i && r['received'] == r['distinct_seq'] }
      SELECT l.lane, l.committed_seq, COUNT(b.seq) AS received, COUNT(DISTINCT b.seq) AS distinct_seq
      FROM sync_site_lanes l JOIN sync_received_batches b
        ON b.site_code = l.site_code AND b.epoch = l.epoch AND b.lane = l.lane
      WHERE l.site_code = 'SITEA' GROUP BY l.lane, l.committed_seq
    SQL
  end
end

# ---------------------------------------------------------------------------
scene 'power_cut', '3. Power cut at central in the middle of a batch' do
  with_agent_stopped('a') do
    step 'Arm the fault: central will die after applying the next batch, before COMMIT'
    File.write(File.join(ROOT, 'tmp/site_sync_crash_next_batch'), '1')
    patient = register_patient(:a, given: 'Power', family: 'Cut')
    lanes_before = rows(:central, "SELECT lane, committed_seq FROM sync_site_lanes WHERE site_code = 'SITEA' ORDER BY lane")
    sh('bin/rake site_sync:push', node: :a)
    check('nothing from the crashed batch is at central') do
      !at_central?('person', patient[:uuid]) &&
        value(:central, "SELECT COUNT(*) FROM sync_site_mirror WHERE row_uuid = '#{patient[:uuid]}'").to_i.zero?
    end
    check('central did not move its sequence numbers') do
      rows(:central, "SELECT lane, committed_seq FROM sync_site_lanes WHERE site_code = 'SITEA' ORDER BY lane") == lanes_before
    end
    check('Site A still holds the batch as unacknowledged') { unsent(:a).positive? }

    step 'Central is back: Site A simply sends the same batch again'
    sh('bin/rake site_sync:push', node: :a)
    check('the patient is at central exactly once') do
      value(:central, "SELECT COUNT(*) FROM person WHERE uuid = '#{patient[:uuid]}'").to_i == 1
    end
    check('Site A queue is empty') { unsent(:a).zero? }
  end
end

# ---------------------------------------------------------------------------
scene 'lost_ack', '4. Acknowledgement lost: central committed, Site A never heard back' do
  with_agent_stopped('a') do
    step 'Make the link drop central\'s answers'
    link('A', 'drop-acks')
    patient = register_patient(:a, given: 'Lost', family: 'Ack')
    sh('bin/rake site_sync:push', node: :a)
    batch = rows(:a, "SELECT id, lane, seq, status FROM sync_batches ORDER BY id DESC LIMIT 1").first
    check('central committed the batch') { at_central?('person', patient[:uuid]) }
    check("Site A still thinks batch #{batch['lane']}##{batch['seq']} is unsent") { batch['status'] == 'sealed' }

    step 'Restore the link; Site A resends the same batch'
    link('A', 'restore')
    sh('bin/rake site_sync:push', node: :a)
    ack = JSON.parse(value(:a, "SELECT ack_json FROM sync_batches WHERE id = #{batch['id']}") || '{}')
    check('central recognised the resend and returned its stored answer') { ack['duplicate'] == true }
    check('the patient is at central exactly once') do
      value(:central, "SELECT COUNT(*) FROM person WHERE uuid = '#{patient[:uuid]}'").to_i == 1
    end
    check('the batch was applied once') do
      value(:central, "SELECT COUNT(*) FROM sync_received_batches WHERE site_code = 'SITEA' AND lane = '#{batch['lane']}'
                       AND seq = #{batch['seq']}").to_i == 1
    end
  end
end

# ---------------------------------------------------------------------------
scene 'conflict', '5. Two sites edit the same patient while both are offline' do
  step 'Register a patient at Site A; Site B fetches them for a referral'
  patient = register_patient(:a, given: 'Grace', family: 'Mvula', birthdate: '1988-08-08')
  wait_for('patient at central') { at_central?('person', patient[:uuid]) }
  sh("bin/rake 'site_sync:hydrate[#{patient[:uuid]},referral]'", node: :b)
  b_id = person_id(:b, patient[:uuid])
  check('Site B has the patient (under its own local id)') { !b_id.nil? }
  info "Site A id #{patient[:person_id]}, Site B id #{b_id}"

  step 'Cut both sites off; each edits a different field of the same name, and both change the birth date'
  link('A', 'cut')
  link('B', 'cut')
  db(:a).query("UPDATE person_name SET family_name = 'Mvula-Banda' WHERE person_id = #{patient[:person_id]} AND voided = 0")
  db(:b).query("UPDATE person_name SET given_name = 'Gracious' WHERE person_id = #{b_id} AND voided = 0")
  db(:a).query("UPDATE person SET birthdate = '1988-08-18' WHERE person_id = #{patient[:person_id]}")
  db(:b).query("UPDATE person SET birthdate = '1987-08-08' WHERE person_id = #{b_id}")

  step 'Both links come back'
  link('A', 'restore')
  link('B', 'restore')
  name_sql = ->(node, id) { "SELECT CONCAT(given_name, ' ', family_name) FROM person_name WHERE person_id = #{id} AND voided = 0" }
  ids = { a: patient[:person_id], b: b_id, central: person_id(:central, patient[:uuid]) }
  seconds = wait_for('all three agree on the name', timeout: 90) do
    ids.all? { |node, id| value(node, name_sql.call(node, id)) == 'Gracious Mvula-Banda' }
  end
  info "converged in #{seconds} s"
  check('both edits survived everywhere: "Gracious Mvula-Banda"') do
    ids.all? { |node, id| value(node, name_sql.call(node, id)) == 'Gracious Mvula-Banda' }
  end
  wait_for('birth dates agree', timeout: 60) do
    ids.map { |node, id| value(node, "SELECT birthdate FROM person WHERE person_id = #{id}").to_s }.uniq.size == 1
  end
  birthdates = ids.to_h { |node, id| [node, value(node, "SELECT birthdate FROM person WHERE person_id = #{id}").to_s] }
  info "birth date now: #{birthdates}"
  check('all three hold the same birth date') { birthdates.values.uniq.size == 1 }
  conflict = rows(:central, "SELECT * FROM sync_conflicts WHERE row_uuid = '#{patient[:uuid]}' AND column_name = 'birthdate'").first
  check('the birth date clash is open for review, not silently resolved') { conflict && conflict['status'] == 'open' }
  info "review item: kept #{conflict&.dig('kept_value')} (#{conflict&.dig('kept_site')}), " \
       "other value #{conflict&.dig('losing_value')} (#{conflict&.dig('losing_site')})"
end

# ---------------------------------------------------------------------------
scene 'quarantine', '6. A bad record is quarantined; the rest keeps flowing' do
  patient = SHARED[:patient_a] || register_patient(:a, given: 'Quara', family: 'Ntine')
  request_id = "demo-#{SecureRandom.hex(4)}"
  encounter_uuid = SecureRandom.uuid

  step 'Site A saves a visit dated 3 days in the future, with two observations, in one request'
  db(:a).query('START TRANSACTION')
  db(:a).query("SET @sync_request_id = '#{request_id}', @sync_endpoint = 'POST /api/v1/encounters (demo)'")
  db(:a).query(<<~SQL)
    INSERT INTO encounter (encounter_type, patient_id, provider_id, location_id, encounter_datetime, creator,
                           date_created, uuid, program_id)
    VALUES (#{VITALS}, #{patient[:person_id]}, #{admin_person_id(:a)}, '1', NOW() + INTERVAL 3 DAY, 2, NOW(),
            '#{encounter_uuid}', #{OPD_PROGRAM})
  SQL
  encounter_id = value(:a, 'SELECT LAST_INSERT_ID()')
  obs_uuids = [70, 71].map do |kg|
    uuid = SecureRandom.uuid
    db(:a).query(<<~SQL)
      INSERT INTO obs (person_id, concept_id, encounter_id, obs_datetime, location_id, value_numeric, creator,
                       date_created, uuid)
      VALUES (#{patient[:person_id]}, #{WEIGHT}, #{encounter_id}, NOW(), '1', #{kg}, 2, NOW(), '#{uuid}')
    SQL
    uuid
  end
  db(:a).query('SET @sync_request_id = NULL, @sync_endpoint = NULL')
  db(:a).query('COMMIT')
  other = register_patient(:a, given: 'Flowing', family: 'Normally')

  wait_for('quarantine at central') do
    value(:central, "SELECT COUNT(*) FROM sync_quarantine WHERE request_id = '#{request_id}' AND status = 'open'").to_i == 3
  end
  rows(:central, "SELECT table_name, reason, details FROM sync_quarantine WHERE request_id = '#{request_id}'").each do |r|
    info "#{r['table_name'].ljust(10)} #{r['reason'].ljust(20)} #{r['details']}"
  end
  check('the visit is quarantined for a clinical sanity check') do
    value(:central, "SELECT reason FROM sync_quarantine WHERE row_uuid = '#{encounter_uuid}'") == 'clinical_sanity'
  end
  check('its observations are parked with it, not lost') do
    value(:central, "SELECT COUNT(*) FROM sync_quarantine WHERE row_uuid IN ('#{obs_uuids.join("','")}') AND status = 'open'").to_i == 2
  end
  wait_for('other patient at central') { at_central?('person', other[:uuid]) }
  check('other data from Site A still reached central') { at_central?('person', other[:uuid]) }
  check('central keeps the quarantined rows in its backup copy of Site A') do
    value(:central, "SELECT COUNT(*) FROM sync_site_mirror WHERE row_uuid = '#{encounter_uuid}'").to_i == 1
  end
  _, status, = api(:a, :get, '/api/v1/site_sync/status')
  check('Site A can see its own quarantine list') { status['quarantine'].any? { |q| q['row_uuid'] == encounter_uuid } }

  step 'The clinician corrects the date at Site A'
  db(:a).query("UPDATE encounter SET encounter_datetime = NOW() WHERE uuid = '#{encounter_uuid}'")
  wait_for('visit and both observations applied') do
    at_central?('encounter', encounter_uuid) && obs_uuids.all? { |u| at_central?('obs', u) }
  end
  check('the corrected visit and its parked observations are now at central') do
    at_central?('encounter', encounter_uuid) && obs_uuids.all? { |u| at_central?('obs', u) }
  end
  check('the quarantine items closed themselves') do
    value(:central, "SELECT COUNT(*) FROM sync_quarantine WHERE request_id = '#{request_id}' AND status = 'open'").to_i.zero?
  end
end

# ---------------------------------------------------------------------------
scene 'void', '7. A patient registered and voided while offline' do
  link('A', 'cut')
  step 'Offline: register a patient, then void the registration (DELETE /api/v1/patients/:id)'
  patient = register_patient(:a, given: 'Duplicate', family: 'Entry')
  status, = api(:a, :delete, "/api/v1/patients/#{patient[:person_id]}?reason=Registered%20twice%20by%20mistake")
  check('the void was accepted at Site A') { [200, 204].include?(status) }
  info "Site A has #{unsent(:a)} changes queued (the registration and the void)"
  link('A', 'restore')
  wait_for('void at central', timeout: 90) do
    value(:central, "SELECT p.voided FROM patient p JOIN person v ON v.person_id = p.patient_id
                     WHERE v.uuid = '#{patient[:uuid]}'").to_i == 1
  end
  row = rows(:central, "SELECT p.voided, p.void_reason, u.username AS voided_by FROM patient p
                        JOIN person v ON v.person_id = p.patient_id LEFT JOIN users u ON u.user_id = p.voided_by
                        WHERE v.uuid = '#{patient[:uuid]}'").first
  info "central: voided=#{row['voided']}, reason=\"#{row['void_reason']}\", voided by #{row['voided_by']}"
  check('central has the record, voided, with the reason and the user who voided it') do
    # MaHIS's void service prefixes the reason it is given (e.g. "[PV:1] ").
    row['voided'].to_i == 1 && row['void_reason'].to_s.end_with?('Registered twice by mistake') && row['voided_by'] == 'admin'
  end
  check('nothing was dropped from the queue: central saw the insert and the void') do
    ops = rows(:central, "SELECT op FROM sync_central_log WHERE row_uuid = '#{patient[:uuid]}' AND table_name = 'patient'
                          ORDER BY gseq").map { |r| r['op'] }
    ops.first == 'I' && ops.include?('U')
  end
end

# ---------------------------------------------------------------------------
scene 'tamper', '8. The queue cannot be edited, and a changed batch is caught' do
  step 'Give the application its own MySQL account (generated by rake site_sync:grants)'
  grants = sh("bin/rake 'site_sync:grants[mahis_app,mahis_sync]'", node: :a, quiet: true)
  db(:a).query("CREATE USER IF NOT EXISTS 'mahis_app'@'%' IDENTIFIED BY 'app'")
  db(:a).query("CREATE USER IF NOT EXISTS 'mahis_sync'@'%' IDENTIFIED BY 'sync'")
  grants.lines.grep(/^GRANT/).each { |sql| db(:a).query(sql.strip.chomp(';')) }
  before = value(:a, 'SELECT COUNT(*) FROM sync_change_log').to_i
  out = `mysql --no-defaults -umahis_app -papp -h127.0.0.1 -P3307 mahis_site_a -e "DELETE FROM sync_change_log" 2>&1`
  info out.lines.grep(/ERROR/).first.to_s.strip
  check('the application account cannot delete queued changes') do
    out.include?('ERROR 1142') && value(:a, 'SELECT COUNT(*) FROM sync_change_log').to_i == before
  end

  with_agent_stopped('a') do
    step 'Someone with full access edits a sealed batch before it is sent'
    link('A', 'cut')
    patient = register_patient(:a, given: 'Honest', family: 'Record')
    sh('bin/rake site_sync:push', node: :a)
    batch = rows(:a, "SELECT id, payload FROM sync_batches WHERE status = 'sealed' AND payload LIKE '%Honest%'
                      ORDER BY id DESC LIMIT 1").first
    db(:a).query("UPDATE sync_batches SET payload = REPLACE(payload, 'Honest', 'Forged') WHERE id = #{batch['id']}")
    link('A', 'restore')
    sh('bin/rake site_sync:push', node: :a)
    check('central refused the altered batch') { !at_central?('person', patient[:uuid]) }
    check('central raised a tamper alert') do
      value(:central, "SELECT COUNT(*) FROM sync_alerts WHERE site_code = 'SITEA' AND kind = 'batch_tampered'").to_i.positive?
    end
    step 'Put the original batch back; it goes through'
    db(:a).query("UPDATE sync_batches SET payload = '#{db(:a).escape(batch['payload'])}' WHERE id = #{batch['id']}")
    sh('bin/rake site_sync:push', node: :a)
    check('the genuine batch was accepted') { at_central?('person', patient[:uuid]) }
  end

  step 'Someone captures a signed request from Site A and sends it again, or changes its parameters'
  secret = sh('echo $SITE_SYNC_SECRET', node: :a, quiet: true).strip
  nonce = SecureRandom.hex(16)
  first, = signed_get('SITEA', secret, '/api/v1/site_sync/changes?cursor=0&limit=1', nonce:)
  replay, body = signed_get('SITEA', secret, '/api/v1/site_sync/changes?cursor=0&limit=1', nonce:)
  altered, = signed_get('SITEA', secret, '/api/v1/site_sync/changes?cursor=0&limit=2000',
                        nonce: SecureRandom.hex(16), sign_path: '/api/v1/site_sync/changes?cursor=0&limit=1')
  check('the original request is accepted') { first == 200 }
  check('the same request sent again is refused as a replay') { replay == 401 && body['error'] == 'replayed' }
  check('a request with altered parameters is refused') { altered == 401 }
end

# ---------------------------------------------------------------------------
scene 'clock', '8b. A site server\'s clock is a year ahead' do
  patient = SHARED[:patient_a] || register_patient(:a, given: 'Clock', family: "Skew#{unique_letters}")
  new_family = "Mtambo#{unique_letters}"
  step 'Site A\'s clock jumps a year ahead while a clinician edits a name'
  db(:a).query('SET TIMESTAMP = UNIX_TIMESTAMP() + 31536000')
  db(:a).query("UPDATE person_name SET family_name = '#{new_family}' WHERE person_id = #{patient[:person_id]} AND voided = 0")
  db(:a).query('SET TIMESTAMP = DEFAULT')
  name_at_central = lambda do
    value(:central, "SELECT n.family_name FROM person_name n JOIN person p ON p.person_id = n.person_id
                     WHERE p.uuid = '#{patient[:uuid]}' AND n.voided = 0")
  end
  wait_for('edit at central') { name_at_central.call == new_family }
  check('central still accepts the site\'s changes (the site is not blocked)') { name_at_central.call == new_family }
  check('central raised a clock alert') do
    value(:central, "SELECT COUNT(*) FROM sync_alerts WHERE site_code = 'SITEA' AND kind = 'clock_ahead'").to_i.positive?
  end
  limit = ((Time.now.to_r + 3600) * 1_000_000).to_i
  check('the year-ahead time did not enter central\'s records') do
    value(:central, "SELECT MAX(hlc) FROM sync_site_mirror WHERE site_code = 'SITEA'").to_i < limit
  end
  check('Site A\'s clock state was pulled back to central\'s time') do
    value(:a, "SELECT value FROM sync_state WHERE name = 'hlc'").to_i < limit
  end
  step 'The next ordinary change from Site A flows normally'
  later = register_patient(:a, given: 'After', family: "Clockfix#{unique_letters}")
  wait_for('next change at central') { at_central?('person', later[:uuid]) }
  check('later changes sync normally') { at_central?('person', later[:uuid]) }
end

# ---------------------------------------------------------------------------
scene 'reconcile', '9. Silent corruption at Site B is found and repaired' do
  name_row = rows(:b, "SELECT n.person_name_id, n.uuid, n.family_name FROM person_name n
                       WHERE n.voided = 0 ORDER BY n.person_name_id LIMIT 1").first
  obs_row = rows(:b, "SELECT o.obs_id, o.uuid FROM obs o WHERE NOT EXISTS (SELECT 1 FROM obs c WHERE c.obs_group_id = o.obs_id)
                      ORDER BY o.obs_id LIMIT 1").first
  queued = unsent(:b)

  step "Corrupt Site B behind the application's back (no capture): change a name, delete an observation"
  db(:b).query('SET @sync_capture_paused = 1')
  db(:b).query("UPDATE person_name SET family_name = 'CORRUPTED' WHERE person_name_id = #{name_row['person_name_id']}")
  db(:b).query("DELETE FROM obs WHERE obs_id = #{obs_row['obs_id']}")
  db(:b).query('SET @sync_capture_paused = NULL')
  check('the corruption was not captured (nothing new queued)') { unsent(:b) == queued }

  step 'Nightly reconciliation (Merkle comparison with central\'s copy)'
  report = JSON.parse(sh('bin/rake site_sync:reconcile', node: :b, quiet: true)[/\{.*\}/m])
  report['tables'].each do |table, t|
    next unless t['differences'].to_i.positive?

    info "#{table.ljust(20)} missing at site: #{t['central_only'].size}, differs: #{t['different'].size} " \
         "(held for review: #{t['held_for_review'].size})"
  end
  measure 'reconciliation bytes exchanged (6 tables, 2 bad rows)', "#{report['bytes_exchanged']} B"
  measure 'reconciliation time', "#{report['seconds']} s"
  differences = report['tables'].values.sum { |t| t['differences'].to_i }
  check('exactly the two damaged rows were found') { differences == 2 }
  check('the deleted observation was restored automatically, with its original id') do
    value(:b, "SELECT uuid FROM obs WHERE obs_id = #{obs_row['obs_id']}") == obs_row['uuid']
  end
  check('the changed name was NOT overwritten automatically: it is held for a data officer') do
    report['tables']['person_name']['held_for_review'] == [name_row['uuid']] &&
      value(:b, "SELECT family_name FROM person_name WHERE person_name_id = #{name_row['person_name_id']}") == 'CORRUPTED'
  end
  check('central raised a review alert') do
    value(:central, "SELECT COUNT(*) FROM sync_alerts WHERE site_code = 'SITEB' AND kind = 'reconciliation_review'").to_i.positive?
  end

  step 'The data officer confirms central\'s copy is right (REPAIR_DIFFERENT=central)'
  sh('REPAIR_DIFFERENT=central bin/rake site_sync:reconcile', node: :b, quiet: true)
  check('the name was repaired') do
    value(:b, "SELECT family_name FROM person_name WHERE person_name_id = #{name_row['person_name_id']}") == name_row['family_name']
  end
  again = JSON.parse(sh('bin/rake site_sync:reconcile', node: :b, quiet: true)[/\{.*\}/m])
  check('a second run finds nothing') { again['tables'].values.sum { |t| t['differences'].to_i }.zero? }
end

# ---------------------------------------------------------------------------
scene 'restore', '10. Site B\'s server is lost and rebuilt from central' do
  tables = %w[person patient person_name patient_identifier encounter obs]
  sample = rows(:b, 'SELECT uuid, person_id FROM person ORDER BY person_id').to_h { |r| [r['uuid'], r['person_id']] }
  obs_ids = rows(:b, 'SELECT uuid, obs_id FROM obs').to_h { |r| [r['uuid'], r['obs_id']] }
  wait_for('Site B queue empty') { unsent(:b).zero? }
  sh("#{PROTO}/bin/stop agent_b", quiet: true)
  old_secret = sh('echo $SITE_SYNC_SECRET', node: :b, quiet: true).strip

  step 'Administrator freezes Site B at central: new epoch, old server\'s secret revoked'
  frozen = admin(:post, '/api/v1/site_sync/admin/sites/SITEB/freeze')
  info "epoch #{frozen['epoch']}, restore point #{frozen['restore_point_gseq']}"

  step 'The old server is still running somewhere and tries to send'
  register_patient(:b, given: 'Old', family: 'Server')
  out = sh('bin/rake site_sync:push', node: :b, quiet: true)
  check('central refuses the old server') { out.include?('push: idle') && out.include?('failures') }
  check('central raised an alert about it') do
    value(:central, "SELECT COUNT(*) FROM sync_alerts WHERE site_code = 'SITEB' AND kind = 'bad_signature'").to_i.positive?
  end

  step 'Disaster: the server is replaced; the new one has only the MaHIS install (reference data)'
  db(:b).query('SET @sync_capture_paused = 1, FOREIGN_KEY_CHECKS = 0')
  tables.reverse_each { |t| db(:b).query("DELETE FROM `#{t}`") }
  %w[sync_change_log sync_batches sync_state sync_row_versions sync_pending_apply sync_quarantine_notices].each do |t|
    db(:b).query("DELETE FROM #{t}")
  end
  db(:b).query('SET @sync_capture_paused = NULL, FOREIGN_KEY_CHECKS = 1')
  info "Site B now has #{value(:b, 'SELECT COUNT(*) FROM person')} people"

  step 'Restore onto the new server (rake site_sync:restore, with the newly issued secret)'
  File.write(File.join(ROOT, 'tmp/site_sync_mysql/secret_SITEB'), frozen['secret'])
  started = Time.now
  out = sh('bin/rake site_sync:restore', node: :b)
  elapsed = (Time.now - started).round(1)
  restored_rows = tables.sum { |t| value(:b, "SELECT COUNT(*) FROM `#{t}`").to_i }
  measure 'restore time (incl. ~15 s Rails boot)', "#{elapsed} s for #{restored_rows} rows"

  check('every table matches central\'s checksum') { out.scan('checksum OK').size == tables.size }
  check('every person has the same local id as before') do
    sample.all? { |uuid, id| person_id(:b, uuid) == id }
  end
  check('every observation has the same local id as before') do
    obs_ids.all? { |uuid, id| value(:b, "SELECT obs_id FROM obs WHERE uuid = '#{uuid}'") == id }
  end
  check('central shows Site B active in the new epoch') do
    rows(:central, "SELECT status, epoch FROM sync_sites WHERE site_code = 'SITEB'").first.values_at('status', 'epoch') ==
      ['active', frozen['epoch']]
  end
  check('the record typed on the old server after the freeze is not there (re-enter from paper)') do
    value(:b, "SELECT COUNT(*) FROM person_name WHERE given_name = 'Old' AND family_name = 'Server'").to_i.zero?
  end

  step 'Site B goes live again'
  sh("#{PROTO}/bin/start agents", quiet: true)
  fresh = register_patient(:b, given: 'Back', family: 'Online')
  wait_for('new patient at central') { at_central?('person', fresh[:uuid]) }
  check('new work at Site B reaches central in the new epoch') { at_central?('person', fresh[:uuid]) }
  out = sh("SITE_SYNC_SECRET=#{old_secret} bin/rake site_sync:heartbeat", node: :b, quiet: true)
  check('the old server stays locked out') { out.include?('unauthenticated') }
end

# ---------------------------------------------------------------------------
scene 'measure', '11. Measurements' do
  step 'Capture cost: save a visit with 20 observations, 200 times (committed), without and with the triggers'
  out = with_agent_stopped('a') { sh('bin/rake site_sync:benchmark', node: :a) }
  without, with, overhead = out.match(/without capture ([\d.]+) ms, with capture ([\d.]+) ms, overhead ([-\d.]+)%/)
                               &.captures&.map(&:to_f)
  measure 'visit + 20 obs, no capture', "#{without} ms"
  measure 'visit + 20 obs, with capture', "#{with} ms"
  measure 'capture overhead', "#{overhead}%"
  check('capture overhead is under the 10% target') { overhead && overhead < 10 }

  step 'Wire size of sealed batches'
  require 'zlib'
  sizes = rows(:a, 'SELECT payload, event_count FROM sync_batches WHERE event_count >= 20 ORDER BY id DESC LIMIT 20')
  raw = sizes.sum { |r| r['payload'].bytesize }
  gz = sizes.sum { |r| Zlib.gzip(r['payload']).bytesize }
  events = sizes.sum { |r| r['event_count'].to_i }
  if events.positive?
    measure 'bytes per change, uncompressed', (raw.to_f / events).round
    measure 'bytes per change, gzip (as sent)', (gz.to_f / events).round
    measure 'changes per minute a 256 kbit/s link can carry (at 50% cap)', ((32_000 * 0.5 * 60) / (gz.to_f / events)).round
  end
end

# ---------------------------------------------------------------------------
selected = ARGV.empty? ? SCENES.keys : ARGV
title('Waiting for both sites\' rollout snapshots to reach central')
%w[A B].each { |site| sh("#{PROTO}/bin/link #{site} restore", quiet: true) }
info "waited #{wait_for('snapshots acknowledged', timeout: 900) { unsent(:a).zero? && unsent(:b).zero? }} s"
selected.each do |name|
  heading, block = SCENES.fetch(name) { abort "unknown scene #{name}; scenes: #{SCENES.keys.join(', ')}" }
  title(heading)
  # A scene that failed half-way must not leave a link cut for the next one.
  %w[A B].each { |site| sh("#{PROTO}/bin/link #{site} restore", quiet: true) }
  begin
    block.call
  rescue Demo::Failure => e
    results << ["#{name}: #{e.message}", false]
    puts "    FAIL  #{e.message}"
  end
end

passed = results.count { |_, ok| ok }
title("Result: #{passed}/#{results.size} checks passed")
results.reject { |_, ok| ok }.each { |description, _| puts "  FAILED: #{description}" }
measurements.each { |k, v| puts "  #{k}: #{v}" }
File.write(File.join(ROOT, 'tmp/site_sync_mysql/demo_report.json'),
           JSON.pretty_generate('checks' => results.map { |d, ok| { 'check' => d, 'passed' => ok } },
                                'measurements' => measurements, 'at' => Time.now.to_s))
exit(passed == results.size ? 0 : 1)
