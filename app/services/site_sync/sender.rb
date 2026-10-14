# frozen_string_literal: true

module SiteSync
  # Site -> central. Seals captured changes into ordered, hash-chained batches
  # and pushes them, critical lane first.
  #
  # A batch is stored (sync_batches) before it is sent, so a resend after a
  # lost acknowledgement is byte-for-byte the same batch. A batch counts as
  # sent only when central's acknowledgement names its sequence number and
  # hash, which central returns only after the batch has committed.
  class Sender
    GENESIS = '0' * 64
    SEAL_LOCK = 'site_sync_seal'

    attr_reader :stats

    def initialize(client: Client.new)
      @client = client
      @conn = ActiveRecord::Base.lease_connection
      @stats = Hash.new(0)
    end

    # Push until there is nothing left (or central cannot be reached).
    # Returns :idle, :sent or :offline.
    def run_once(max_batches: 500)
      sent = false
      Config::LANES.each do |lane|
        max_batches.times do
          batch = next_unacked(lane) || seal(lane)
          break unless batch

          result = push(batch)
          return :offline if result == :offline
          break if result == :refused

          sent = true
        end
        # Bulk rows (visits, observations) point at critical rows (patients):
        # hold them back while the critical lane is stuck.
        break if lane == 'critical' && next_unacked('critical')
      end
      sent ? :sent : :idle
    end

    # Group unsealed log rows into the next batch of a lane. Runs at READ
    # COMMITTED so it takes no gap locks: triggers keep inserting while it
    # works, and anything committed after this read goes in the next batch.
    def seal(lane)
      with_seal_lock do
        @conn.transaction(isolation: :read_committed) do
          rows = @conn.select_all(<<~SQL).to_a
            SELECT * FROM sync_change_log WHERE batch_id IS NULL AND lane = #{q(lane)}
            ORDER BY id LIMIT #{Config.batch_max_events}
          SQL
          return nil if rows.empty?

          events = build_events(rows)
          epoch = State.epoch
          last = @conn.select_one(<<~SQL)
            SELECT seq, batch_hash FROM sync_batches WHERE epoch = #{epoch} AND lane = #{q(lane)} ORDER BY seq DESC LIMIT 1
          SQL
          seq = last ? last['seq'].to_i + 1 : 1
          prev_hash = last ? last['batch_hash'] : GENESIS
          events_json = events.to_json
          batch_hash = Digest::SHA256.hexdigest("#{prev_hash}#{events_json}")
          header = { 'site' => Config.site_code, 'epoch' => epoch, 'lane' => lane, 'seq' => seq,
                     'prev_hash' => prev_hash, 'batch_hash' => batch_hash, 'schema_version' => Config.schema_version,
                     'event_count' => events.size }
          payload = { 'header' => header, 'events_json' => events_json }.to_json

          @conn.execute(<<~SQL)
            INSERT INTO sync_batches (lane, epoch, seq, first_log_id, last_log_id, event_count, prev_hash, batch_hash,
                                      payload, status, created_at)
            VALUES (#{q(lane)}, #{epoch}, #{seq}, #{events.first['log_id']}, #{events.last['log_id']}, #{events.size},
                    #{q(prev_hash)}, #{q(batch_hash)}, #{q(payload)}, 'sealed', NOW(6))
          SQL
          batch_id = @conn.select_value('SELECT LAST_INSERT_ID()')
          @conn.execute(<<~SQL)
            UPDATE sync_change_log SET batch_id = #{batch_id}
            WHERE id IN (#{events.map { |e| e['log_id'] }.join(',')})
          SQL
          @stats[:sealed_events] += events.size
          @conn.select_one("SELECT * FROM sync_batches WHERE id = #{batch_id}")
        end
      end
    end

    def push(batch)
      response = @client.post('/api/v1/site_sync/batches', batch['payload'])
      @stats[:bytes_sent] += response.bytes_sent
      body = response.body

      if response.status == 200 && body['committed_seq'].to_i == batch['seq'].to_i && body['batch_hash'] == batch['batch_hash']
        acknowledge(batch, body)
        :acked
      elsif response.status == 409 && body['expected_seq'] && body['error'] == 'sequence_gap'
        rewind(batch['lane'], body['expected_seq'].to_i)
        :rewound
      else
        note_failure(batch, "HTTP #{response.status}: #{body.to_json.slice(0, 400)}")
        :refused
      end
    rescue Client::Unreachable => e
      note_failure(batch, e.message)
      :offline
    end

    private

    # Wire events: the row exactly as the site holds it, plus uuids for every
    # foreign key. The HLC is assigned here, in log order, from the persisted
    # last value, so it never goes backwards.
    def build_events(rows)
      codec = Codec.new(@conn)
      hlc = State.get_i('hlc', 0)
      bytes = 0
      events = []
      rows.each do |row|
        after = row['after_json'] && JSON.parse(row['after_json'])
        before = row['before_json'] && JSON.parse(row['before_json'])
        hlc = Hlc.tick(hlc, Hlc.from_time(row['captured_at']))
        event = {
          'event_id' => "#{Config.site_code}-#{State.epoch}-#{row['id']}", 'log_id' => row['id'],
          'table' => row['table_name'], 'op' => row['op'], 'uuid' => row['row_uuid'], 'pk' => row['row_pk'],
          'hlc' => hlc, 'row' => after, 'before' => before,
          'refs' => after ? codec.encode_refs(row['table_name'], after) : {},
          'row_hash' => row['row_hash'], 'origin' => row['origin'],
          'request_id' => row['request_id'], 'endpoint' => row['endpoint'], 'job' => row['job'],
          'user_uuid' => row['user_uuid'], 'captured_at' => row['captured_at'].iso8601(6)
        }
        bytes += event.to_json.bytesize
        break if events.any? && bytes > Config.batch_max_bytes

        events << event
      end
      State.set('hlc', hlc)
      events
    end

    def acknowledge(batch, ack)
      @conn.transaction do
        @conn.execute(<<~SQL)
          UPDATE sync_batches SET status = 'acked', acked_at = NOW(6), ack_json = #{q(ack.to_json)}, last_error = NULL
          WHERE id = #{batch['id']}
        SQL
        Array(ack['quarantined']).each do |item|
          @conn.execute(<<~SQL)
            INSERT INTO sync_quarantine_notices (event_id, table_name, row_uuid, reason, details, status, created_at)
            VALUES (#{q(item['event_id'])}, #{q(item['table'])}, #{q(item['uuid'])}, #{q(item['reason'])},
                    #{q(item['details'])}, 'open', NOW(6))
            ON DUPLICATE KEY UPDATE reason = VALUES(reason), details = VALUES(details)
          SQL
        end
        Array(ack['resolved']).each do |uuid|
          @conn.execute(<<~SQL)
            UPDATE sync_quarantine_notices SET status = 'resolved', resolved_at = NOW(6)
            WHERE row_uuid = #{q(uuid)} AND status = 'open'
          SQL
        end
      end
      @stats[:acked_batches] += 1
      @stats[:acked_events] += batch['event_count'].to_i
      @stats[:quarantined] += Array(ack['quarantined']).size
    end

    # Central expects an earlier sequence number than the one we sent (it
    # lost batches, for example after its own restore): send again from there.
    # Batches are kept locally, so nothing has to be rebuilt.
    def rewind(lane, expected_seq)
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET status = 'sealed'
        WHERE epoch = #{State.epoch} AND lane = #{q(lane)} AND seq >= #{expected_seq}
      SQL
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET status = 'acked', acked_at = COALESCE(acked_at, NOW(6))
        WHERE epoch = #{State.epoch} AND lane = #{q(lane)} AND seq < #{expected_seq}
      SQL
      @stats[:rewinds] += 1
    end

    def note_failure(batch, message)
      @conn.execute(<<~SQL)
        UPDATE sync_batches SET attempts = attempts + 1, last_error = #{q(message.slice(0, 1000))} WHERE id = #{batch['id']}
      SQL
      @stats[:failures] += 1
    end

    def next_unacked(lane)
      @conn.select_one(<<~SQL)
        SELECT * FROM sync_batches WHERE epoch = #{State.epoch} AND lane = #{q(lane)} AND status = 'sealed'
        ORDER BY seq LIMIT 1
      SQL
    end

    def with_seal_lock
      got = @conn.select_value("SELECT GET_LOCK(#{q(SEAL_LOCK)}, 30)")
      raise 'Could not take the seal lock' unless got.to_i == 1

      yield
    ensure
      @conn.select_value("SELECT RELEASE_LOCK(#{q(SEAL_LOCK)})") if got.to_i == 1
    end

    def q(value)
      @conn.quote(value)
    end
  end
end
