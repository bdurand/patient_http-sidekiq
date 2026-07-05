# frozen_string_literal: true

# In-memory payload store for testing external storage behavior.
class TestPayloadStore < PatientHttp::PayloadStore::Base
  PatientHttp::PayloadStore::Base.register :test_store, self

  @payloads = {}

  class << self
    attr_reader :payloads

    def clear!
      @payloads = {}
    end
  end

  def store_json(key, json)
    self.class.payloads[key] = json
    key
  end

  def fetch(key)
    json = self.class.payloads[key]
    JSON.parse(json) if json
  end

  def delete(key)
    self.class.payloads.delete(key)
    true
  end
end
