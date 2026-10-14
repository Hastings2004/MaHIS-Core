# frozen_string_literal: true

module SiteSync
  # Rebuilds this site's data from central's backup copy (design section 8).
  #
  # Before this runs, an administrator freezes the site at central, which
  # opens a new epoch and issues a new secret for the new server (the old
  # server's secret stops working). Then, on the new server:
  #   1. the site is put in "restoring" mode (the API refuses requests)
  #   2. every synced table is downloaded in resumable chunks and written with
  #      its original local ids, so printed labels and lab orders stay valid
  #   3. each table is checksummed and compared with central's manifest; a
  #      mismatching table is downloaded again
  #   4. the site joins the new epoch, catches up on changes made elsewhere
  #      during the restore, and opens for logins
  class Restore
    CHUNK = 2000

    attr_reader :report

    def initialize(client: Client.new, log: ->(msg) { puts msg })
      @client = client
      @conn = ActiveRecord::Base.lease_connection
      @log = log
      @report = { 'tables' => {} }
    end

    def run
      started = Time.now
      manifest = fetch('/api/v1/site_sync/restore/manifest')
      @log.call("Restoring #{Config.site_code} into epoch #{manifest['epoch']}; " \
                "central's copy is complete up to #{manifest['last_received_at'] || 'the start'}")
      State.set('mode', 'restoring')

      Context.capture_paused do
        @conn.execute('SET FOREIGN_KEY_CHECKS = 0')
        clear_local_data
        Config.table_names.each do |table|
          expected = manifest['tables'].fetch(table)
          2.times do |attempt|
            download(table)
            actual = Merkle.table_digest(Merkle.site_digests(@conn, table, 2))
            ok = actual == expected['digest']
            @report['tables'][table] = { 'rows' => expected['count'], 'checksum_ok' => ok, 'attempts' => attempt + 1 }
            @log.call("  #{table}: #{expected['count']} rows, checksum #{ok ? 'OK' : 'MISMATCH'}")
            break if ok
          end
        end
      ensure
        @conn.execute('SET FOREIGN_KEY_CHECKS = 1')
      end

      failed = @report['tables'].reject { |_, t| t['checksum_ok'] }.keys
      raise "Restore verification failed for: #{failed.join(', ')}. The site stays closed." if failed.any?

      @conn.transaction do
        State.set('epoch', manifest['epoch'])
        State.set('pull_cursor', manifest['restore_point_gseq'])
        State.set('hlc', [State.get_i('hlc', 0), manifest['max_hlc'].to_i].max)
      end
      complete = @client.post('/api/v1/site_sync/restore/complete',
                              { tables: @report['tables'].transform_values { |t| t['checksum_ok'] } })
      raise "Central did not accept the restore: #{complete.body}" unless complete.status == 200

      caught_up = Puller.new(client: @client).run_once
      State.set('mode', 'normal')
      @report.merge!('epoch' => manifest['epoch'], 'data_safe_up_to' => manifest['last_received_at'],
                     'catch_up' => caught_up.to_s, 'seconds' => (Time.now - started).round(1))
      @log.call("Restore complete in #{@report['seconds']}s. Changes made after #{manifest['last_received_at']} " \
                'had not reached central and must be re-entered from paper.')
      @report
    end

    private

    def fetch(path, params = {})
      response = @client.get(path, params)
      raise "Restore refused: HTTP #{response.status} #{response.body}" unless response.status == 200

      response.body
    end

    # A replacement server may hold stale or partial data: start from nothing.
    def clear_local_data
      Config.table_names.reverse_each { |table| @conn.execute("DELETE FROM `#{table}`") }
      %w[sync_change_log sync_batches sync_row_versions sync_pending_apply sync_quarantine_notices].each do |table|
        @conn.execute("DELETE FROM #{table}")
      end
    end

    def download(table)
      store = RowStore.new(@conn)
      @conn.execute("DELETE FROM `#{table}`")
      after_id = 0
      loop do
        page = fetch('/api/v1/site_sync/restore/export', table:, after_id:, limit: CHUNK)
        @conn.transaction { page['rows'].each { |row| store.put_exact(table, row) } }
        break if page['rows'].size < CHUNK

        after_id = page['last_id']
      end
    end
  end
end
