# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Central administration: register sites, freeze a site for restore,
      # review quarantine, and the sync dashboard. Protected by
      # SITE_SYNC_ADMIN_TOKEN (header X-Admin-Token, or ?token= for the
      # dashboard in a browser).
      class AdminController < ActionController::API
        include ActionController::MimeResponds

        before_action :require_admin

        # POST /api/v1/site_sync/admin/sites { site_code, name }
        def register
          secret = SecureRandom.hex(32)
          ::SiteSync::Central.register_site(params.require(:site_code), name: params.fetch(:name, params[:site_code]), secret:)
          render json: { site_code: params[:site_code], secret: }
        end

        # POST /api/v1/site_sync/admin/sites/:code/freeze
        # Step 1-2 of a restore: stop the old server (its secret is replaced)
        # and open a new epoch for the replacement.
        def freeze
          site = ::SiteSync::Central.site(params[:code])
          return render json: { error: 'unknown_site' }, status: :not_found unless site

          secret = SecureRandom.hex(32)
          ::SiteSync::Central.with_feed_lock do
            connection.execute(<<~SQL)
              UPDATE sync_sites SET status = 'restoring', epoch = epoch + 1, secret = #{q(secret)},
                restore_point_gseq = (SELECT COALESCE(MAX(gseq), 0) FROM sync_central_log), updated_at = NOW(6)
              WHERE site_code = #{q(params[:code])}
            SQL
          end
          site = ::SiteSync::Central.site(params[:code])
          ::SiteSync::Central.alert(params[:code], 'frozen',
                                    "Frozen for restore; epoch #{site['epoch']} opened and the old server's secret revoked")
          render json: { site_code: params[:code], epoch: site['epoch'].to_i, secret:,
                         restore_point_gseq: site['restore_point_gseq'].to_i }
        end

        # GET /api/v1/site_sync/admin/quarantine
        def quarantine
          render json: connection.select_all(<<~SQL).to_a
            SELECT id, site_code, table_name, row_uuid, reason, details, parent_uuid, request_id, status, created_at
            FROM sync_quarantine ORDER BY id DESC LIMIT 200
          SQL
        end

        # POST /api/v1/site_sync/admin/quarantine/:id/release
        # A data officer has fixed the cause (for example added the missing
        # reference data): apply the record and anything parked behind it.
        def release
          item = connection.select_one("SELECT * FROM sync_quarantine WHERE id = #{params[:id].to_i}")
          return render json: { error: 'not_found' }, status: :not_found unless item

          outcome = ::SiteSync::CentralIngest.new(item['site_code']).release(item)
          render json: outcome
        end

        # POST /api/v1/site_sync/admin/quarantine/:id/reject
        def reject
          connection.execute(<<~SQL)
            UPDATE sync_quarantine SET status = 'rejected', resolved_at = NOW(6) WHERE id = #{params[:id].to_i}
          SQL
          head :no_content
        end

        # GET /api/v1/site_sync/admin/conflicts
        def conflicts
          render json: connection.select_all(
            'SELECT * FROM sync_conflicts ORDER BY id DESC LIMIT 200'
          ).to_a
        end

        # GET /api/v1/site_sync/admin/dashboard(.json)
        def dashboard
          data = ::SiteSync::Dashboard.new(connection).data
          respond_to do |format|
            format.json { render json: data }
            format.any { render html: ::SiteSync::Dashboard.html(data).html_safe, content_type: 'text/html' }
          end
        end

        private

        def require_admin
          token = request.headers['X-Admin-Token'].presence || params[:token]
          expected = ::SiteSync::Config.admin_token
          return if ::SiteSync::Config.central? && expected.present? && token.present? &&
                    ActiveSupport::SecurityUtils.secure_compare(expected, token)

          render json: { error: 'unauthorized' }, status: :unauthorized
        end

        def connection
          ActiveRecord::Base.lease_connection
        end

        def q(value)
          connection.quote(value)
        end
      end
    end
  end
end
