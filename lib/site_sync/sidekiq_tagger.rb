# frozen_string_literal: true

module SiteSync
  # Sidekiq server middleware: changes made by a background job are tagged
  # with the job's class, the way API requests are tagged with their endpoint.
  class SidekiqTagger
    def call(_worker, job, _queue, &)
      Context.tag(job: "sidekiq:#{job['wrapped'] || job['class']}", request_id: job['jid'], &)
    end
  end
end
