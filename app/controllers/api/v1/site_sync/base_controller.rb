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
          expected = @site && ::SiteSync::Client.signature(@site['secret'], request.method, request.path, request.raw_post)
          given = request.headers['X-Site-Signature'].to_s
          return if expected && ActiveSupport::SecurityUtils.secure_compare(expected, given)

          if @site
            ::SiteSync::Central.alert(@site['site_code'], 'bad_signature',
                                      "Refused #{request.method} #{request.path}: signature does not match the site's " \
                                      'current secret (old or revoked server?)')
          end
          render json: { status: 'refused', error: 'unauthenticated' }, status: :unauthorized
        end
      end
    end
  end
end
