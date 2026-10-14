# frozen_string_literal: true

module SiteSync
  # Sidekiq entry point for the pull loop (see PushJob).
  class PullJob
    include Sidekiq::Job
    sidekiq_options queue: 'site_sync', retry: false, lock: :until_executed

    def perform
      Puller.new.run_once
    end
  end
end
