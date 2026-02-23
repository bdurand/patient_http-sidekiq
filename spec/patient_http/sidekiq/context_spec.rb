# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Sidekiq::Context do
  describe ".with_job" do
    let(:job_data) do
      {
        "class" => "TestWorkers::Worker",
        "jid" => "test-jid",
        "args" => ["arg1", "arg2"]
      }
    end

    it "sets and clears the job context correctly" do
      expect(PatientHttp::Sidekiq::Context.current_job).to be_nil

      PatientHttp::Sidekiq::Context.with_job(job_data) do
        current_job = PatientHttp::Sidekiq::Context.current_job
        expect(current_job).to eq(job_data)
      end

      expect(PatientHttp::Sidekiq::Context.current_job).to be_nil
    end
  end
end
