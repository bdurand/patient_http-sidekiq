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

    it "mounts the Async HTTP dashboard page with a link to the extension stylesheet" do
      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Async HTTP Statistics")
      expect(last_response.body).to include("<h3>Sidekiq Processes</h3>")
      expect(last_response.body).to include("patient-http/css/patient_http.css")
    end

    it "serves the extension stylesheet" do
      get "/patient-http/css/patient_http.css", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(".stat-label")
    end

    it "shows the statistics and capacity of each processor" do
      config = PatientHttp::Sidekiq::Configuration.new
      config.processor(:llm, max_connections: 20)
      stats = PatientHttp::Sidekiq::Stats.new(config)
      stats.record_request(200, 0.5, processor_name: "llm")
      stats.flush
      monitor = PatientHttp::Sidekiq::TaskMonitor.new(
        config,
        processors: -> { {default: {inflight: 1, max_capacity: 100}, llm: {inflight: 3, max_capacity: 20}} }
      )
      monitor.ping_process

      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("<h3>Processors</h3>")
      expect(last_response.body).to include("llm")
    end

    it "lists the requests that are in flight" do
      config = PatientHttp::Sidekiq::Configuration.new
      monitor = PatientHttp::Sidekiq::TaskMonitor.new(config)
      task = PatientHttp::RequestTask.new(
        request: PatientHttp::Request.new(:get, "https://user:secret@api.example.com/v1/things?token=abc"),
        task_handler: PatientHttp::Sidekiq::TaskHandler.new({"class" => "TestWorker", "jid" => "web-jid", "args" => []}),
        callback: TestCallback
      )
      monitor.register(task, processor_name: :llm)

      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("<h3>In-Flight Requests</h3>")
      expect(last_response.body).to include("https://api.example.com/v1/things")
      expect(last_response.body).not_to include("secret")
    end

    it "omits the in-flight section when no request is in flight" do
      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.body).not_to include("<h3>In-Flight Requests</h3>")
    end

    it "omits the per-processor breakdown when only one processor is configured" do
      PatientHttp::Sidekiq::TaskMonitor.new(PatientHttp::Sidekiq::Configuration.new).ping_process

      get "/patient-http", {}, {"rack.session" => {}}

      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("<h3>Processors</h3>")
    end
  end

  RSpec.describe PatientHttp::Sidekiq::WebUI do
    describe ".processor_rows" do
      it "combines the cumulative statistics with the reported capacity" do
        rows = described_class.processor_rows(
          {"llm" => {"requests" => 4, "duration" => 2.0, "errors" => 1, "max_capacity_exceeded" => 2, "max_inflight" => 17}},
          {"llm" => {inflight: 5, max_capacity: 20}}
        )

        expect(rows).to eq([{
          name: "llm",
          inflight: 5,
          peak_inflight: 17,
          max_capacity: 20,
          utilization: 25.0,
          requests: 4,
          errors: 1,
          max_capacity_exceeded: 2,
          avg_duration: 0.5
        }])
      end

      it "includes processors that only one of the two sources knows about" do
        rows = described_class.processor_rows(
          {"retired" => {"requests" => 1, "duration" => 1.0}},
          {"llm" => {inflight: 0, max_capacity: 20}}
        )

        expect(rows.map { |row| row[:name] }).to eq(["llm", "retired"])
        expect(rows.first).to include(requests: 0, avg_duration: 0.0, peak_inflight: 0)
        expect(rows.last).to include(inflight: 0, max_capacity: 0, utilization: 0)
      end

      it "returns no rows when a single processor has no statistics of its own" do
        rows = described_class.processor_rows(nil, {"default" => {inflight: 1, max_capacity: 100}})

        expect(rows).to eq([])
      end
    end
  end
else
  RSpec.describe "patient_http/sidekiq/web" do
    it "raises a LoadError naming the minimum supported Sidekiq version" do
      expect { require "patient_http/sidekiq/web" }.to raise_error(LoadError, /sidekiq >= 7.3/)
    end
  end
end
