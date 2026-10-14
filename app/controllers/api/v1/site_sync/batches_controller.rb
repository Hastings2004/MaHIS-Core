# frozen_string_literal: true

module Api
  module V1
    module SiteSync
      # POST /api/v1/site_sync/batches: one hash-chained batch from a site.
      # Answers only after the batch has committed at central.
      class BatchesController < BaseController
        def create
          result = ::SiteSync::CentralIngest.new(site_code).call(payload)
          render json: result.body, status: result.status
        end
      end
    end
  end
end
