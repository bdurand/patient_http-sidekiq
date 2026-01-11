# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncHttp::ClassHelper do
  describe ".resolve_class_name" do
    it "returns the class constant" do
      klass = described_class.resolve_class_name("Sidekiq::AsyncHttp::ClassHelper")
      expect(klass).to eq(Sidekiq::AsyncHttp::ClassHelper)
    end

    it "raises NameError for unknown class" do
      expect {
        described_class.resolve_class_name("NonExistent::ClassName")
      }.to raise_error(NameError)
    end
  end
end
