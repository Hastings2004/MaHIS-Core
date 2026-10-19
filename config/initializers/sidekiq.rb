require 'sidekiq'
require 'sidekiq-cron'
require 'sidekiq-unique-jobs'

# Global job defaults
Sidekiq.default_job_options = {
  'retry' => true,
  'lock' => :until_and_while_executing,
  'lock_ttl' => 90.minutes.to_i
}

Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch('SIDEKIQ_REDIS_URL', 'redis://localhost:6379/0') }

  config.on(:startup) do
    next if ENV.fetch('COUCHDB_NIGHTLY_COMPACTION_ENABLED', 'true') == 'false'

    CouchdbCompactionService.disable_automatic_compaction!
  rescue StandardError => e
    Rails.logger.warn("[CouchDB Compaction] Could not disable continuous compaction: #{e.class}: #{e.message}")
  end

  # Unique job middleware
  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end

  config.server_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Server
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('SIDEKIQ_REDIS_URL', 'redis://localhost:6379/0') }

  config.client_middleware do |chain|
    chain.add SidekiqUniqueJobs::Middleware::Client
  end
end

schedule_file = "config/schedule.yml"

if File.exist?(schedule_file) && Sidekiq.server?
  Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file)
end
