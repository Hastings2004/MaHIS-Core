# frozen_string_literal: true

# Two-way site <-> central sync (prototype). See config/site_sync_tables.yml.
namespace :site_sync do
  desc 'Write the capture triggers to db/site_sync_triggers.sql'
  task generate: :environment do
    path = Rails.root.join('db/site_sync_triggers.sql')
    File.write(path, SiteSync::TriggerGenerator.script)
    puts "Wrote #{path}"
  end

  desc 'Install (or reinstall) the capture triggers on this site'
  task install: :environment do
    connection = ActiveRecord::Base.lease_connection
    SiteSync::TriggerGenerator.all_sql.each { |sql| connection.execute(sql) }
    puts "Installed #{SiteSync::TriggerGenerator.expected_trigger_names.size} capture triggers"
  end

  desc 'Remove the capture triggers'
  task uninstall: :environment do
    connection = ActiveRecord::Base.lease_connection
    SiteSync::Config.table_names.flat_map { |t| SiteSync::TriggerGenerator.drop_sql(t) }.each { |sql| connection.execute(sql) }
    puts 'Capture triggers removed'
  end

  desc 'CI check: config matches the schema, triggers are installed, no hard deletes on synced tables'
  task check: :environment do
    connection = ActiveRecord::Base.lease_connection
    problems = []

    SiteSync::Config.table_names.each do |table|
      unless connection.table_exists?(table)
        problems << "#{table}: listed in site_sync_tables.yml but missing from the database"
        next
      end
      problems << "#{table}: has no uuid column and no uuid_via" unless
        SiteSync::Config.columns(table).include?('uuid') || SiteSync::Config.uuid_via(table)
      (SiteSync::Config.refs(table).keys - SiteSync::Config.columns(table)).each do |col|
        problems << "#{table}.#{col}: listed in refs but not a column"
      end
    end

    if ENV['SKIP_TRIGGER_CHECK'].blank?
      installed = SiteSync::Heartbeat.new(client: nil).installed_triggers
      missing = SiteSync::TriggerGenerator.expected_trigger_names - installed
      problems << "missing capture triggers: #{missing.join(', ')}" if missing.any?
    end

    # TRUNCATE and hard deletes bypass or blur the audit trail; synced tables
    # are voided, never deleted. (Deletes are still captured as tombstones.)
    models = %w[Person Patient PersonName PatientIdentifier Encounter Observation]
    pattern = /\b(#{models.join('|')})\b[^#\n]*\.(delete_all|destroy_all|delete|destroy)\b|TRUNCATE\s+(TABLE\s+)?`?(#{SiteSync::Config.table_names.join('|')})\b/i
    Dir[Rails.root.join('{app,lib}/**/*.rb')].each do |file|
      next if file.include?('/site_sync')

      File.foreach(file).with_index(1) do |line, number|
        problems << "#{file.delete_prefix("#{Rails.root}/")}:#{number}: hard delete on a synced table" if line.match?(pattern)
      end
    end

    if problems.empty?
      puts 'site_sync:check OK'
    else
      puts problems
      abort "site_sync:check found #{problems.size} problem(s)"
    end
  end

  desc 'Print GRANTs so the app cannot alter the sync queue: rake site_sync:grants[app_user,sync_user]'
  task :grants, %i[app_user sync_user] => :environment do |_, args|
    connection = ActiveRecord::Base.lease_connection
    db = connection.current_database
    app = "'#{args[:app_user] || 'mahis_app'}'@'%'"
    agent = "'#{args[:sync_user] || 'mahis_sync'}'@'%'"
    tables = connection.select_values(<<~SQL)
      SELECT TABLE_NAME FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = #{connection.quote(db)} AND TABLE_TYPE = 'BASE TABLE'
    SQL
    statements = tables.flat_map do |table|
      if table.start_with?('sync_')
        # The capture triggers write the log with their definer's rights, so
        # the application itself only ever needs to read these tables.
        ["GRANT SELECT ON `#{db}`.`#{table}` TO #{app};",
         "GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db}`.`#{table}` TO #{agent};"]
      elsif SiteSync::Config.synced?(table)
        ["GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db}`.`#{table}` TO #{app};",
         "GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db}`.`#{table}` TO #{agent};"]
      else
        ["GRANT SELECT, INSERT, UPDATE, DELETE ON `#{db}`.`#{table}` TO #{app};",
         "GRANT SELECT ON `#{db}`.`#{table}` TO #{agent};"]
      end
    end
    puts statements
  end

  desc 'Rollout: queue every existing row once, so central gets a full copy of this site'
  task snapshot: :environment do
    connection = ActiveRecord::Base.lease_connection
    SiteSync::Config.table_names.each do |table|
      via = SiteSync::Config.uuid_via(table)
      uuid = via ? 'v.`uuid`' : 't.`uuid`'
      join = via ? "JOIN `#{via}` v ON v.`#{SiteSync::Config.pk(via)}` = t.`#{SiteSync::Config.pk(table)}`" : ''
      connection.execute(<<~SQL)
        INSERT INTO sync_change_log
          (lane, table_name, op, row_pk, row_uuid, before_json, after_json, row_hash, origin, job, captured_at)
        SELECT #{connection.quote(SiteSync::Config.lane(table))}, #{connection.quote(table)}, 'S',
               t.`#{SiteSync::Config.pk(table)}`, #{uuid}, NULL, #{SiteSync::RowSql.json(table, 't.')},
               #{SiteSync::RowSql.hash_expr(table, 't.')}, 'local', 'rake:site_sync:snapshot', NOW(6)
        FROM `#{table}` t #{join}
        ORDER BY t.`#{SiteSync::Config.pk(table)}`
      SQL
      puts "#{table}: #{connection.select_value("SELECT ROW_COUNT()")} rows queued"
    end
  end

  desc 'Measure capture cost: committed visit + 20 obs saves, with and without triggers (stop the agent first)'
  task benchmark: :environment do
    connection = ActiveRecord::Base.lease_connection
    runs = Integer(ENV.fetch('RUNS', 200))
    patient_id = connection.select_value('SELECT patient_id FROM patient ORDER BY patient_id DESC LIMIT 1')
    provider = connection.select_value("SELECT person_id FROM users WHERE username = 'admin'")
    marker = "bench-#{SecureRandom.hex(4)}"
    encounter_ids = []

    save_visit = lambda do
      connection.transaction do
        connection.execute(<<~SQL)
          INSERT INTO encounter (encounter_type, patient_id, provider_id, location_id, encounter_datetime, creator,
                                 date_created, uuid, program_id)
          VALUES (6, #{patient_id}, #{provider}, '1', NOW(), 2, NOW(), UUID(), 14)
        SQL
        encounter_id = connection.select_value('SELECT LAST_INSERT_ID()')
        encounter_ids << encounter_id
        values = Array.new(20) do |i|
          "(#{patient_id}, 53325, #{encounter_id}, NOW(), '1', #{50 + i}, '#{marker}', 2, NOW(), UUID())"
        end
        connection.execute(<<~SQL)
          INSERT INTO obs (person_id, concept_id, encounter_id, obs_datetime, location_id, value_numeric, comments,
                           creator, date_created, uuid)
          VALUES #{values.join(', ')}
        SQL
      end
    end
    time = lambda do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      runs.times { save_visit.call }
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 / runs).round(2)
    end

    capture_tables = %w[encounter obs]
    drop = -> { capture_tables.each { |t| SiteSync::TriggerGenerator.drop_sql(t).each { |s| connection.execute(s) } } }
    install = -> { capture_tables.each { |t| SiteSync::TriggerGenerator.create_sql(t).each { |s| connection.execute(s) } } }
    job = 'rake:site_sync:benchmark'
    begin
      SiteSync::Context.tag(job:) do
        drop.call
        without = time.call
        install.call
        with = time.call
        puts "visit + 20 obs, committed, #{runs} runs: without capture #{without} ms, with capture #{with} ms, " \
             "overhead #{((with / without - 1) * 100).round(1)}%"
      end
    ensure
      drop.call
      install.call
      # Remove exactly the benchmark's rows and log entries, without syncing them.
      SiteSync::Context.capture_paused do
        connection.execute("DELETE FROM obs WHERE comments = #{connection.quote(marker)}")
        encounter_ids.each_slice(500) do |ids|
          connection.execute("DELETE FROM encounter WHERE encounter_id IN (#{ids.join(',')})")
        end
      end
      connection.execute("DELETE FROM sync_change_log WHERE job = #{connection.quote(job)} AND batch_id IS NULL")
    end
  end

  desc 'Push captured changes to central once'
  task push: :environment do
    sender = SiteSync::Sender.new
    puts "push: #{sender.run_once} #{sender.stats.to_h}"
  end

  desc 'Pull subscribed changes from central once'
  task pull: :environment do
    puller = SiteSync::Puller.new
    puts "pull: #{puller.run_once} #{puller.stats.to_h}"
  end

  desc 'Send one heartbeat'
  task heartbeat: :environment do
    puts SiteSync::Heartbeat.new.send_once.to_json
  end

  desc 'Reconcile this site against central (REPAIR=false to only report; ' \
       'REPAIR_DIFFERENT=central|site to settle rows that differ, after review)'
  task reconcile: :environment do
    report = SiteSync::Reconciler.new.run(repair: ENV['REPAIR'] != 'false', different: ENV['REPAIR_DIFFERENT'].presence)
    puts JSON.pretty_generate(report)
  end

  desc 'Fetch one patient from central: rake site_sync:hydrate[uuid_or_identifier,reason]'
  task :hydrate, %i[key reason] => :environment do |_, args|
    key = args[:key].to_s
    by_uuid = key.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    result = SiteSync::Puller.new.hydrate(reason: args[:reason] || 'referral',
                                          uuid: (key if by_uuid), identifier: (key unless by_uuid))
    puts result.to_json
  end

  desc 'Rebuild this site from central (after an admin froze it and issued a new secret)'
  task restore: :environment do
    report = SiteSync::Restore.new.run
    puts JSON.pretty_generate(report)
  end

  desc 'Central: register a site and print its secret: rake site_sync:register_site[SITEA,"Site A"]'
  task :register_site, %i[code name] => :environment do |_, args|
    secret = ENV['SECRET'].presence || SecureRandom.hex(32)
    SiteSync::Central.register_site(args[:code], name: args[:name] || args[:code], secret:)
    puts secret
  end

  desc 'Run the sync loops: push every 30 s, pull every 2 min, heartbeat every 5 min'
  task agent: :environment do
    push_every = Float(ENV.fetch('SITE_SYNC_PUSH_EVERY', 30))
    pull_every = Float(ENV.fetch('SITE_SYNC_PULL_EVERY', 120))
    beat_every = Float(ENV.fetch('SITE_SYNC_HEARTBEAT_EVERY', 300))
    max_backoff = Float(ENV.fetch('SITE_SYNC_MAX_BACKOFF', 900))
    log = ->(msg) { puts "#{Time.now.strftime('%H:%M:%S')} [#{SiteSync::Config.site_code}] #{msg}"; $stdout.flush }

    backoff = push_every
    next_push = next_pull = next_beat = Time.now
    stop = false
    %w[INT TERM].each { |signal| trap(signal) { stop = true } }
    log.call("agent started (push #{push_every}s, pull #{pull_every}s, heartbeat #{beat_every}s)")

    until stop
      now = Time.now
      begin
        if now >= next_push
          sender = SiteSync::Sender.new
          result = sender.run_once
          if result == :offline
            log.call("central unreachable; retrying in #{backoff.round}s")
            next_push = now + backoff
            backoff = [backoff * 2, max_backoff].min
          else
            log.call("pushed #{sender.stats.to_h}") if result == :sent
            backoff = push_every
            next_push = now + push_every
          end
        end
        if now >= next_pull
          puller = SiteSync::Puller.new
          result = puller.run_once
          log.call("pulled #{puller.stats.to_h}") if result == :applied
          next_pull = now + pull_every
        end
        if now >= next_beat
          SiteSync::Heartbeat.new.send_once
          next_beat = now + beat_every
        end
      rescue StandardError => e
        log.call("error: #{e.class}: #{e.message}")
      end
      sleep 0.5
    end
    log.call('agent stopped')
  end
end
