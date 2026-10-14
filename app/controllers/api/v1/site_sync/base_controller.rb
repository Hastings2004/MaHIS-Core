# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # Endpoints a site's sync agent calls on central. They authenticate the
      # site (HMAC signature with the site's secret), not a user, so they do
      # not inherit ApplicationController's user login.
      class BaseController < ActionController::API
        before_action :require_central
        before_action :authenticate_site

        rescue_from JSON::ParserError do
          render json: { status: 'refused', error: 'invalid_json' }, status: :bad_request
        end

        protected

        attr_reader :site

        def site_code
          site['site_code']
        end

        def payload
          @payload ||= request.raw_post.present? ? JSON.parse(request.raw_post) : {}
        end

        def connection
          ActiveRecord::Base.lease_connection
        end

        def q(value)
          connection.quote(value)
        end

        private

        def require_central
          return if ::SiteSync::Config.central?

          render json: { status: 'refused', error: 'not_central' }, status: :not_found
        end

        def authenticate_site
          @site = ::SiteSync::Central.site(request.headers['X-Site-Code'].to_s)
          timestamp = request.headers['X-Site-Timestamp'].to_s
          nonce = request.headers['X-Site-Nonce'].to_s
          expected = @site && nonce.present? &&
                     ::SiteSync::Client.signature(@site['secret'], request.method, request.fullpath, timestamp, nonce,
                                                  request.raw_post)
          given = request.headers['X-Site-Signature'].to_s
          unless expected && ActiveSupport::SecurityUtils.secure_compare(expected, given)
            if @site
              ::SiteSync::Central.alert(@site['site_code'], 'bad_signature',
                                        "Refused #{request.method} #{request.path}: signature does not match the site's " \
                                        'current secret (old or revoked server?)')
            end
            return render json: { status: 'refused', error: 'unauthenticated' }, status: :unauthorized
          end

          # Each signed request is accepted once. There is deliberately no
          # tight time window: a site with a wrong clock must still be able to
          # sync (its clock is handled in CentralIngest), so nonces are kept
          # for 90 days instead.
          connection.execute(<<~SQL)
            INSERT INTO sync_request_nonces (nonce, site_code, site_timestamp, seen_at)
            VALUES (#{q(nonce)}, #{q(site_code)}, #{q(timestamp.to_i)}, NOW(6))
          SQL
        rescue ActiveRecord::RecordNotUnique
          ::SiteSync::Central.alert(site_code, 'replayed_request', "Refused a repeated request: #{request.method} #{request.path}")
          render json: { status: 'refused', error: 'replayed' }, status: :unauthorized
        end
      end
    end
  end
end
