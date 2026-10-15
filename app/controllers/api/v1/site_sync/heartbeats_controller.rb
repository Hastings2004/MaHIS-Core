# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # POST /api/v1/site_sync/heartbeat: lag, backlog and clock check.
      class HeartbeatsController < BaseController
        MAX_CLOCK_OFFSET_S = 300

        def create
          central_us = ::SiteSync::Hlc.now_us
          offset_s = ((payload['site_time_us'].to_i - central_us) / 1_000_000.0).round(1)
          beat = payload.merge('clock_offset_s' => offset_s)
          connection.execute(<<~SQL)
            UPDATE sync_sites SET last_heartbeat_at = NOW(6), heartbeat_json = #{q(beat.to_json)}, updated_at = NOW(6)
            WHERE site_code = #{q(site_code)}
          SQL
          if offset_s.abs > MAX_CLOCK_OFFSET_S
            ::SiteSync::Central.alert(site_code, 'clock_drift', "Site clock is #{offset_s}s off central's")
          end
          if payload['triggers_installed'].to_i < payload['triggers_expected'].to_i
            ::SiteSync::Central.alert(site_code, 'capture_incomplete',
                                      "Only #{payload['triggers_installed']} of #{payload['triggers_expected']} capture triggers installed")
          end
          # Request nonces only need to outlive any realistic replay attempt.
          # (Production: partition this table by day and drop old partitions;
          # it gets about 3 500 rows a day per site.)
          connection.execute(
            "DELETE FROM sync_request_nonces WHERE seen_at < NOW(6) - INTERVAL #{NONCE_DAYS} DAY LIMIT 10000"
          )
          render json: { central_time_us: central_us, clock_offset_s: offset_s }
        end
      end
    end
  end
end
