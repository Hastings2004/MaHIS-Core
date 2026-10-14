# frozen_string_literal: true

module SiteSync
  # Sidekiq entry point for the heartbeat (see PushJob).
  class HeartbeatJob
    include Sidekiq::Job
    sidekiq_options queue: 'site_sync', retry: false, lock: :until_executed

    def perform
      Heartbeat.new.send_once
    end
  end
end
