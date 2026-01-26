# frozen_string_literal: true

module Sidekiq::AsyncHttp
  # Sidekiq client middleware to serialize Response and Error objects
  # into hashes before enqueuing jobs. This allows passing the Response
  # and Error objects directly as job arguments rather than serializing
  # and deserializing them manually.
  class SerializeResponseMiddleware
    include Sidekiq::ClientMiddleware

    def call(worker_class, job, queue, redis_pool)
      first_arg = job["args"]&.first
      if first_arg.is_a?(Response) || first_arg.is_a?(Error)
        job["args"][0] = first_arg.as_json.merge("_sidekiq_async_http_class" => first_arg.class.name)
      end

      yield
    end
  end
end
