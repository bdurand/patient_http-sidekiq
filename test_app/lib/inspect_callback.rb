# frozen_string_literal: true

class InspectCallback
  include Sidekiq::Job

  REDIS_KEY = "test_app_inspect_response"

  class << self
    # Clear the stored response from Redis.
    #
    # @return [void]
    def clear_response
      ::Sidekiq.redis { |conn| conn.del(REDIS_KEY) }
    end

    # Store a response payload in Redis with 60-second expiry.
    #
    # @param payload [Hash] The response or error payload to store.
    # @return [void]
    def set_response(payload)
      ::Sidekiq.redis { |conn| conn.set(REDIS_KEY, JSON.pretty_generate(payload), ex: 60) }
    end

    # Get the stored response from Redis.
    #
    # @return [String, nil] The JSON response string or nil if not present.
    def get_response
      ::Sidekiq.redis { |conn| conn.get(REDIS_KEY) }
    end
  end

  def on_complete(response)
    self.class.set_response(response: response.as_json)
  end

  def on_error(error)
    self.class.set_response(error: error.as_json)
  end
end
