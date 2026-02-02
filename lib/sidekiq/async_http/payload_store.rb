# frozen_string_literal: true

module Sidekiq
  module AsyncHttp
    module PayloadStore
      autoload :Base, File.join(__dir__, "payload_store/base")
      autoload :FileStore, File.join(__dir__, "payload_store/file_store")
    end
  end
end
