# frozen_string_literal: true

module SiteSync
  # Central's one-page view of every site: lag, backlog, clock, quarantine,
  # last reconciliation, plus recent alerts.
  class Dashboard
    def initialize(connection = ActiveRecord::Base.lease_connection)
      @conn = connection
    end

    def data
      {
        'generated_at' => Time.now.iso8601,
        'sites' => @conn.select_all('SELECT * FROM sync_sites ORDER BY site_code').to_a.map { |site| site_row(site) },
        'feed_size' => @conn.select_value('SELECT COUNT(*) FROM sync_central_log').to_i,
        'open_conflicts' => @conn.select_value("SELECT COUNT(*) FROM sync_conflicts WHERE status = 'open'").to_i,
        'logged_conflicts' => @conn.select_value("SELECT COUNT(*) FROM sync_conflicts WHERE status = 'logged'").to_i,
        'quarantine' => @conn.select_all(<<~SQL).to_a,
          SELECT id, site_code, table_name, row_uuid, reason, details, status FROM sync_quarantine
          ORDER BY id DESC LIMIT 10
        SQL
        'alerts' => @conn.select_all(
          'SELECT site_code, kind, message, created_at FROM sync_alerts ORDER BY id DESC LIMIT 15'
        ).to_a
      }
    end

    def site_row(site)
      code = @conn.quote(site['site_code'])
      beat = site['heartbeat_json'] ? JSON.parse(site['heartbeat_json']) : {}
      last_run = @conn.select_one(
        "SELECT report_json, finished_at FROM sync_reconciliation_runs WHERE site_code = #{code} ORDER BY id DESC LIMIT 1"
      )
      run = last_run && JSON.parse(last_run['report_json'])
      {
        'site_code' => site['site_code'], 'name' => site['name'], 'status' => site['status'], 'epoch' => site['epoch'].to_i,
        'heartbeat_age_s' => site['last_heartbeat_at'] && (Time.now - site['last_heartbeat_at']).round,
        'backlog' => beat['backlog'] || {}, 'oldest_unsent_s' => beat['oldest_unsent_seconds'],
        'clock_offset_s' => beat['clock_offset_s'], 'mode' => beat['mode'],
        'parked' => beat['pending_apply'].to_i, 'orphaned' => beat['orphaned'].to_i,
        'triggers' => beat['triggers_installed'] && "#{beat['triggers_installed']}/#{beat['triggers_expected']}",
        'last_batch_at' => @conn.select_value("SELECT MAX(received_at) FROM sync_received_batches WHERE site_code = #{code}"),
        'events_received' => @conn.select_value(
          "SELECT COALESCE(SUM(event_count), 0) FROM sync_received_batches WHERE site_code = #{code}"
        ).to_i,
        'backup_rows' => @conn.select_value(
          "SELECT COUNT(*) FROM sync_site_mirror WHERE site_code = #{code} AND deleted = 0"
        ).to_i,
        'open_quarantine' => @conn.select_value(
          "SELECT COUNT(*) FROM sync_quarantine WHERE site_code = #{code} AND status = 'open'"
        ).to_i,
        'reconciliation' => run && {
          'status' => run['status'], 'at' => last_run['finished_at'],
          'differences' => (run['tables'] || {}).values.sum { |t| t['differences'].to_i },
          'bytes' => run['bytes_exchanged']
        }
      }
    end

    def self.html(data)
      esc = ->(value) { ERB::Util.html_escape(value.to_s) }
      sites = data['sites'].map do |s|
        backlog = s['backlog'].map { |lane, n| "#{lane}: #{n}" }.join(', ').presence || '0'
        rec = s['reconciliation']
        rec_text = rec ? "#{rec['status']}, #{rec['differences']} diff, #{rec['bytes']} B" : '—'
        status_class = s['status'] == 'active' ? 'ok' : 'warn'
        lag_class = s['oldest_unsent_s'].to_i > 300 ? 'warn' : 'ok'
        clock_class = s['clock_offset_s'].to_f.abs > 300 ? 'warn' : 'ok'
        <<~ROW
          <tr>
            <td><b>#{esc[s['name']]}</b><br><small>#{esc[s['site_code']]}</small></td>
            <td class="#{status_class}">#{esc[s['status']]}<br><small>epoch #{s['epoch']}</small></td>
            <td>#{esc[backlog]}</td>
            <td class="#{lag_class}">#{s['oldest_unsent_s'] || '—'} s</td>
            <td>#{s['events_received']}<br><small>last #{esc[s['last_batch_at']&.strftime('%H:%M:%S')]}</small></td>
            <td>#{s['backup_rows']}</td>
            <td class="#{s['open_quarantine'].positive? ? 'warn' : 'ok'}">#{s['open_quarantine']}</td>
            <td class="#{s['orphaned'].positive? ? 'warn' : 'ok'}">#{s['parked']}<br><small>#{s['orphaned']} orphaned</small></td>
            <td class="#{clock_class}">#{s['clock_offset_s'] || '—'} s</td>
            <td>#{esc[s['triggers']]}</td>
            <td>#{esc[rec_text]}</td>
            <td>#{s['heartbeat_age_s'] || '—'} s</td>
          </tr>
        ROW
      end.join
      quarantine = data['quarantine'].map do |q|
        "<tr><td>#{q['id']}</td><td>#{esc[q['site_code']]}</td><td>#{esc[q['table_name']]}</td>" \
          "<td><code>#{esc[q['row_uuid']]}</code></td><td>#{esc[q['reason']]}</td><td>#{esc[q['details']]}</td>" \
          "<td>#{esc[q['status']]}</td></tr>"
      end.join
      alerts = data['alerts'].map do |a|
        "<tr><td>#{esc[a['created_at']&.strftime('%H:%M:%S')]}</td><td>#{esc[a['site_code']]}</td>" \
          "<td>#{esc[a['kind']]}</td><td>#{esc[a['message']]}</td></tr>"
      end.join

      <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="5">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>MaHIS Sync</title>
        <style>
          :root { --bg:#fafaf9; --fg:#1c1917; --muted:#78716c; --line:#e7e5e4; --ok:#15803d; --warn:#b45309; --card:#fff; }
          @media (prefers-color-scheme: dark) { :root { --bg:#1c1917; --fg:#f5f5f4; --muted:#a8a29e; --line:#44403c;
            --ok:#4ade80; --warn:#fbbf24; --card:#292524; } }
          body { font: 14px/1.4 system-ui, sans-serif; background: var(--bg); color: var(--fg); margin: 0; padding: 16px; }
          h1 { font-size: 20px; margin: 0 0 4px; } h2 { font-size: 15px; margin: 24px 0 8px; }
          .meta { color: var(--muted); margin-bottom: 16px; }
          .wrap { overflow-x: auto; background: var(--card); border: 1px solid var(--line); border-radius: 8px; }
          table { border-collapse: collapse; width: 100%; } th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
          th { color: var(--muted); font-weight: 600; font-size: 12px; } small { color: var(--muted); }
          .ok { color: var(--ok); } .warn { color: var(--warn); font-weight: 600; } code { font-size: 12px; }
        </style></head><body>
        <h1>MaHIS two-way sync</h1>
        <div class="meta">Central feed: #{data['feed_size']} changes · conflicts: #{data['open_conflicts']} open for review,
          #{data['logged_conflicts']} auto-resolved · refreshed #{esc[data['generated_at']]}</div>
        <div class="wrap"><table>
          <tr><th>Site</th><th>Status</th><th>Unsent</th><th>Oldest unsent</th><th>Events received</th><th>Backup rows</th>
              <th>Quarantine</th><th>Parked at site</th><th>Clock offset</th><th>Triggers</th><th>Last reconciliation</th><th>Heartbeat</th></tr>
          #{sites}
        </table></div>
        <h2>Quarantine (latest)</h2>
        <div class="wrap"><table><tr><th>#</th><th>Site</th><th>Table</th><th>Record</th><th>Reason</th><th>Details</th><th>Status</th></tr>
          #{quarantine.presence || '<tr><td colspan="7">Nothing quarantined</td></tr>'}</table></div>
        <h2>Alerts</h2>
        <div class="wrap"><table><tr><th>Time</th><th>Site</th><th>Kind</th><th>Message</th></tr>
          #{alerts.presence || '<tr><td colspan="4">No alerts</td></tr>'}</table></div>
        </body></html>
      HTML
    end
  end
end
