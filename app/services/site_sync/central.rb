# frozen_string_literal: true

module SiteSync
  # Shared helpers for the central node: registered sites, alerts, the
  # downstream feed and subscriptions.
  module Central
    INGEST_LOCK = 'site_sync_central_log'

    module_function

    def connection
      ActiveRecord::Base.lease_connection
    end

    def q(value)
      connection.quote(value)
    end

    def site(code)
      connection.select_one("SELECT * FROM sync_sites WHERE site_code = #{q(code)}")
    end

    def register_site(code, name:, secret:, location_id: nil)
      connection.execute(<<~SQL)
        INSERT INTO sync_sites (site_code, name, location_id, secret, status, epoch, created_at, updated_at)
        VALUES (#{q(code)}, #{q(name)}, #{q(location_id)}, #{q(SecretCipher.encrypt(secret))}, 'active', 1, NOW(6), NOW(6))
        ON DUPLICATE KEY UPDATE name = VALUES(name), location_id = VALUES(location_id),
                                secret = VALUES(secret), updated_at = NOW(6)
      SQL
    end

    # The raw secret for a site row from `site`/`site_code` (its `secret`
    # column is encrypted at rest; see SecretCipher).
    def secret_for(site_row)
      SecretCipher.decrypt(site_row['secret'])
    end

    def alert(site_code, kind, message)
      Rails.logger.warn("[SiteSync] #{site_code} #{kind}: #{message}")
      connection.execute(<<~SQL)
        INSERT INTO sync_alerts (site_code, kind, message, created_at)
        VALUES (#{q(site_code)}, #{q(kind)}, #{q(message)}, NOW(6))
      SQL
    end

    # Serialises everything that appends to sync_central_log, so gseq order is
    # commit order and a site reading "after my cursor" never skips a change
    # committed late. (A production version would use a committed-watermark
    # table instead of one lock.)
    def with_feed_lock
      got = connection.select_value("SELECT GET_LOCK(#{q(INGEST_LOCK)}, 120)")
      raise 'Could not take the central feed lock' unless got.to_i == 1

      yield
    ensure
      connection.select_value("SELECT RELEASE_LOCK(#{q(INGEST_LOCK)})") if got.to_i == 1
    end

    # Central's own HLC, so feed events always carry increasing clocks.
    def next_hlc(seen = 0)
      value = Hlc.receive(State.get_i('central_hlc', 0), seen)
      State.set('central_hlc', value)
      value
    end

    # Append a central row to the downstream feed: the whole row, or with
    # `columns` only those columns (an update sends just what changed, so a
    # site never gets other fields overwritten with an older state).
    # target_site nil = everyone subscribed to the patient except origin_site.
    def publish(table:, op:, uuid:, origin_site:, codec:, store:, target_site: nil, seen_hlc: 0, columns: nil)
      full = op == 'D' ? nil : store.current(table, codec.id_for(table, uuid))
      return if op != 'D' && full.nil?

      refs = full ? codec.encode_refs(table, full) : {}
      patient_uuid = full ? Codec.patient_uuid(table, uuid, refs) : patient_of_deleted(table, uuid)
      row = columns && full ? full.slice(*columns) : full
      refs = refs.slice(*columns) if columns
      hlc = next_hlc(seen_hlc)
      event = { 'table' => table, 'op' => op, 'uuid' => uuid, 'hlc' => hlc, 'row' => row, 'refs' => refs }
      connection.execute(<<~SQL)
        INSERT INTO sync_central_log
          (origin_site, target_site, table_name, op, row_uuid, patient_uuid, hlc, event_json, created_at)
        VALUES (#{q(origin_site)}, #{q(target_site)}, #{q(table)}, #{q(op)}, #{q(uuid)}, #{q(patient_uuid)},
                #{hlc}, #{q(event.to_json)}, NOW(6))
      SQL
    end

    def patient_of_deleted(table, uuid)
      connection.select_value(<<~SQL)
        SELECT patient_uuid FROM sync_central_log
        WHERE table_name = #{q(table)} AND row_uuid = #{q(uuid)} AND patient_uuid IS NOT NULL
        ORDER BY gseq DESC LIMIT 1
      SQL
    end

    def subscribe(site_code, patient_uuid, reason)
      connection.execute(<<~SQL)
        INSERT IGNORE INTO sync_subscriptions (site_code, patient_uuid, reason, created_at)
        VALUES (#{q(site_code)}, #{q(patient_uuid)}, #{q(reason)}, NOW(6))
      SQL
    end
  end
end
