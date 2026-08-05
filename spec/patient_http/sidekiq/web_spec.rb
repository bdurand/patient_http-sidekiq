# frozen_string_literal: true

require "spec_helper"

if Gem::Version.new(::Sidekiq::VERSION) >= Gem::Version.new("7.3")
  require "rack/test"
  require "patient_http/sidekiq/web"

  RSpec.describe "patient_http/sidekiq/web" do
    include Rack::Test::Methods

    def app
      ::Sidekiq::Web
    end

    it "registers the Async HTTP tab with Sidekiq::Web" do
      expect(::Sidekiq::Web.tabs).to include("patient_http_tab" => "patient-http")
    end

    it "mounts the Async HTTP dashboard page" do
      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Async HTTP Statistics")
    end
  end
else
  RSpec.describe "patient_http/sidekiq/web" do
    it "raises a LoadError naming the minimum supported Sidekiq version" do
      expect { require "patient_http/sidekiq/web" }.to raise_error(LoadError, /sidekiq >= 7.3/)
    end
  end
end
