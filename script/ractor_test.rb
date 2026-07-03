# frozen_string_literal: true

require_relative "ractor_test_support"

RactorTestSupport.boot_app!
RactorTestSupport.prepare_database!
context = RactorTestSupport.seed_request_data!
REQUESTS = RactorTestSupport.load_request_specs(context)

PASS = []
FAIL = []

def pass(label)
  puts "  PASS  #{label}"
  PASS << label
end

def fail(label, error)
  message = "#{error.class}: #{error.message}"
  puts "  FAIL  #{label}"
  puts "        #{message}"
  error.backtrace&.first(10)&.each { |line| puts "          #{line}" }
  FAIL << { label: label, message: message }
end

def test_application_shareability
  label = "application is shareable"
  Rails.application.ractorize!

  if Ractor.shareable?(Rails.application)
    pass(label)
  else
    fail(label, RuntimeError.new("#{Rails.application.class} is not shareable"))
  end
rescue => error
  fail(label, error)
end

def test_request(spec)
  label = RactorTestSupport.request_label(spec)
  env = RactorTestSupport.build_env(spec)

  result = Ractor.new(Rails.application, env) do |app, request_env|
    begin
      response = RactorTestSupport.perform_request(app, request_env)
      {
        status: response[:status],
        body: response[:body],
        body_length: response[:body_length],
        location: response[:location],
      }
    rescue => error
      { error: "#{error.class}: #{error.message}", trace: error.backtrace&.first(5)&.join("\n") }
    end
  end.value

  if result[:error]
    fail(label, RuntimeError.new("#{result[:error]}\n#{result[:trace]}"))
    return
  end

  RactorTestSupport.validate_response!(spec, result)

  detail = "#{result[:status]} (#{result[:body_length]} bytes)"
  detail += " -> #{result[:location]}" if result[:location]
  pass("#{label} -> #{detail}")
rescue => error
  fail(label, error)
end

phases = ARGV.map(&:strip)
phases = %w[shareable request] if phases.empty?

puts "Ractor Safety Test"
puts "  Ruby:  #{RUBY_DESCRIPTION}"
puts "  Rails: #{Rails.version}"
puts "  Env:   #{Rails.env}"
puts "=" * 70

if phases.include?("shareable")
  puts
  puts "Phase 1: Application shareability"
  puts "-" * 50
  test_application_shareability
end

if phases.include?("request")
  puts
  puts "Phase 2: HTTP requests in Ractor"
  puts "-" * 50
  Rails.application.ractorize! unless Rails.application.frozen?
  REQUESTS.each { |spec| test_request(spec) }
end

puts
puts "=" * 70
total = PASS.size + FAIL.size
puts "#{PASS.size}/#{total} passed, #{FAIL.size} failed"

if FAIL.any?
  puts
  puts "First failure to fix:"
  puts "  #{FAIL.first[:label]}"
  puts "  #{FAIL.first[:message]}"
  exit 1
end

puts
puts "All Ractor safety tests passed!"
