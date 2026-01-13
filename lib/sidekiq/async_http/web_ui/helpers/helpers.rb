# frozen_string_literal: true

module Sidekiq::AsyncHttp::WebUI::Helpers
  def number_with_delimiter(number)
    number.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
  end

  def h(text)
    Rack::Utils.escape_html(text)
  end

  def utilization_class(utilization)
    if utilization < 50
      'low'
    elsif utilization < 80
      'medium'
    else
      'high'
    end
  end
end
