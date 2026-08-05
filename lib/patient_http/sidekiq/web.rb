# frozen_string_literal: true

# This file exists so that the require path for the web UI can match the
# file path in sidekiq itself: `require patient_http/sidekiq/web`

require_relative "web_ui"
