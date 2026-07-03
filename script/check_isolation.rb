# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"
ENV["RAILS_LOG_LEVEL"] ||= "warn"
ENV["RACTOR_ISOLATION_CAPTURE_BACKTRACE"] ||= "1"

Ractor.warn_frozen_error = true if defined?(Ractor) && Ractor.respond_to?(:warn_frozen_error=)

require "json"
require_relative "check_isolation_runner"

unless ARGV.empty?
  warn "bin/check-isolation does not accept options; it writes results JSON to stdout."
  exit 2
end

result = CheckIsolationRunner.run
$stdout.write(JSON.pretty_generate(result))
$stdout.write("\n")

exit(result[:failed_requests].to_i.zero? && result[:ractorize_error].nil? ? 0 : 1)
