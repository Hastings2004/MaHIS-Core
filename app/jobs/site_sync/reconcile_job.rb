# frozen_string_literal: true

module SiteSync
  # Sidekiq entry point for nightly reconciliation (see PushJob).
  class ReconcileJob
    include Sidekiq::Job
    sidekiq_options queue: 'site_sync', retry: false, lock: :until_executed

    def perform
      Reconciler.new.run
    end
  end
end
