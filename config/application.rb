# frozen_string_literal: true

require_relative 'boot'

require 'rails'
# Pick the frameworks you want:
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'active_storage/engine'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'action_view/railtie'
require 'action_cable/engine'
# require "sprockets/railtie"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

require_relative '../lib/inflate_request_body'

module BHTEmrApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 6.1
    config.eager_load_paths << Rails.root.join('lib')
    config.autoload_paths << Rails.root.join('app/channels')
    config.eager_load_paths << Rails.root.join('app/channels')
    config.active_record.yaml_column_permitted_classes = [Date, Time]
    config.active_record.schema_format = :sql
    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration can go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded after loading
    # the framework and any gems in your application.

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    # Stores a DDE Connection to be used in between requests
    config.dde_connection = nil
    config.time_zone = 'Africa/Blantyre' # Your local time zone
    config.active_record.default_timezone = :local
    config.active_record.time_zone_aware_attributes = false

    config.generators do |g|
      g.orm :active_record, primary_key_type: :integer
    end

    # Action Cable
    config.action_cable.mount_path = '/cable'
    config.action_cable.disable_request_forgery_protection = true
    # Fallback for environments where config/cable.yml is missing.
    # Without this, ActionCable can raise NoMethodError in pubsub_adapter.
    config.action_cable.cable ||= if Rails.env.test? || Rails.env.development?
                                    { 'adapter' => 'async' }
                                  else
                                    {
                                      'adapter' => 'redis',
                                      'url' => ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/1'),
                                      'channel_prefix' => "BHT-EMR-API_#{Rails.env}"
                                    }
                                  end

    # This also configures session_options for use below
    config.session_store :cookie_store, key: '_interslice_session'

    # Inflate gzip-compressed request bodies (e.g. POST /save_patient_record)
    # before Rails parses params. Runs at the front of the stack.
    config.middleware.insert_before 0, InflateRequestBody

    # Gzip responses (e.g. the full record returned by get/save_patient_record)
    # when the client sends Accept-Encoding: gzip. The browser decompresses
    # transparently, so no frontend change is needed. Done in-app because we
    # do not control the nginx `gzip on` directive.
    config.middleware.use Rack::Deflater

    # Required for all session management (regardless of session_store)
    config.middleware.use ActionDispatch::Cookies

    config.middleware.use config.session_store, config.session_options

    # Use Sidekiq for Active Job
    config.active_job.queue_adapter = :sidekiq
  end
end
