# frozen_string_literal: true

require "rails/generators/base"

module PatientHttp
  module Sidekiq
    # Rails generator that creates a commented initializer for applications
    # that want to change the defaults. The gem works without the initializer.
    #
    #   bin/rails generate patient_http:sidekiq:install
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a commented config/initializers/patient_http.rb for patient_http-sidekiq."

      # Creates +config/initializers/patient_http.rb+ from the template.
      #
      # @return [void]
      def create_initializer
        template("initializer.rb", "config/initializers/patient_http.rb")
      end

      # Prints the next steps.
      #
      # @return [void]
      def show_next_steps
        say("")
        say("patient_http-sidekiq is ready to use.", :green)
        say("")
        say("Nothing else is required: the request handler is registered when the gem")
        say("loads and the processor starts and stops with your Sidekiq server.")
        say("")
        say("Make a request from anywhere in your application:")
        say("")
        say("  PatientHttp.get(url, callback: MyCallback, callback_args: {id: 1})")
        say("")
        say("Edit config/initializers/patient_http.rb to change any of the defaults.")
        say("")
      end
    end
  end
end
