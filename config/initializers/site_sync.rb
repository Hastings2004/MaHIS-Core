# frozen_string_literal: true

# Two-way site <-> central sync (prototype). Off unless MAHIS_SYNC_ROLE is set.
# Development logs every SQL statement, including whole sync payloads, which
# slows batch ingest badly; the prototype nodes run at SITE_SYNC_LOG_LEVEL.
Rails.logger.level = ENV['SITE_SYNC_LOG_LEVEL'].to_sym if ENV['MAHIS_SYNC_ROLE'] && ENV['SITE_SYNC_LOG_LEVEL'].present?

if ENV['MAHIS_SYNC_ROLE'] == 'site'
  Sidekiq.configure_server do |config|
    config.server_middleware do |chain|
      chain.add SiteSync::SidekiqTagger
    end
  end
end
