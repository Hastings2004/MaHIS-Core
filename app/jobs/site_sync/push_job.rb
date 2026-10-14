# frozen_string_literal: true

module SiteSync
  # Sidekiq entry point for the push loop, for sites that schedule the sync
  # loops with sidekiq-cron instead of running `rake site_sync:agent`. The
  # sync jobs use their own queue so report jobs cannot delay them.
  class PushJob
    include Sidekiq::Job
    sidekiq_options queue: 'site_sync', retry: false, lock: :until_executed

    def perform
      Sender.new.run_once
    end
  end
end
