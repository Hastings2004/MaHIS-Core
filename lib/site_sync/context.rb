# frozen_string_literal: true

module SiteSync
  # Sets the MySQL session variables the capture triggers read, and always
  # clears them afterwards: connections are pooled, so a tag or a "replica"
  # flag left behind would leak into an unrelated request.
  module Context
    TAGS = %i[request_id endpoint user_uuid job].freeze

    module_function

    def connection
      ActiveRecord::Base.lease_connection
    end

    # Tag every change made inside the block with the request or job that
    # caused it.
    def tag(request_id: nil, endpoint: nil, user_uuid: nil, job: nil)
      set_vars(sync_request_id: request_id, sync_endpoint: endpoint&.slice(0, 160),
               sync_user_uuid: user_uuid, sync_job: job&.slice(0, 160))
      yield
    ensure
      set_vars(sync_request_id: nil, sync_endpoint: nil, sync_user_uuid: nil, sync_job: nil)
    end

    # Changes applied inside the block came from central: they are logged for
    # audit and for central's backup copy, but never re-sent as this site's own
    # edits (no echo loops).
    def as_replica(&)
      with_vars({ sync_origin: 'replica' }, { sync_origin: nil }, &)
    end

    # Nothing inside the block is captured. Only affects this connection, so
    # clinical writes on other connections keep being captured.
    def capture_paused(&)
      with_vars({ sync_capture_paused: 1 }, { sync_capture_paused: nil }, &)
    end

    def with_vars(set, reset)
      set_vars(**set)
      yield
    ensure
      set_vars(**reset)
    end

    def set_vars(**vars)
      assignments = vars.map { |name, value| "@#{name} = #{connection.quote(value)}" }
      connection.execute("SET #{assignments.join(', ')}")
    end
  end
end
