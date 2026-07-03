# frozen_string_literal: true

require "time"

Ractor.warn_frozen_error = true if defined?(Ractor) && Ractor.respond_to?(:warn_frozen_error=)

require_relative "ractor_isolation_warnings"
require_relative "ractor_test_support"

module CheckIsolationRunner
  extend self

  def run
    started_at = Time.now.utc

    unless defined?(Ractor) && Ractor.respond_to?(:check_isolation)
      raise "Ractor.check_isolation is not available in #{RUBY_DESCRIPTION}"
    end

    app = nil
    specs = []

    RactorTestSupport.with_verbosity(false) do
      app = RactorTestSupport.boot_app!
      RactorTestSupport.prepare_database!
      context = RactorTestSupport.seed_request_data!
      specs = RactorTestSupport.load_request_specs(context)
    end

    result = base_result(started_at, specs.size)

    unless app.respond_to?(:ractorize!)
      error = RuntimeError.new("#{app.class} does not respond to ractorize!")
      result[:ractorize_error] = RactorTestSupport.format_error(error)
      result[:requests] = skipped_requests(specs, error)
      return finalize_counts(result)
    end

    begin
      app.ractorize!
      result[:ractorized] = true
      result[:application_shareable] = Ractor.respond_to?(:shareable?) ? Ractor.shareable?(app) : app.frozen?
    rescue StandardError => error
      result[:ractorize_error] = RactorTestSupport.format_error(error)
      result[:requests] = skipped_requests(specs, error)
      return finalize_counts(result)
    ensure
      # Drop boot/ractorization warnings; the report is scoped to requests.
      RactorIsolationWarnings.clear
    end

    existing_slugs = {}
    specs.each do |spec|
      result[:requests] << run_request(app, spec, existing_slugs)
    end

    finalize_counts(result)
  end

  private

  def run_request(app, spec, existing_slugs)
    slug = RactorTestSupport.request_slug(spec, existing_slugs: existing_slugs)
    response = nil
    error = nil

    RactorIsolationWarnings.clear
    begin
      env = RactorTestSupport.build_env(spec)
      RactorIsolationWarnings.run do
        response = RactorTestSupport.perform_request(app, env)
      end
      RactorTestSupport.validate_response!(spec, response)
    rescue StandardError => caught
      error = caught
    end

    groups = warning_groups_from_capture

    {
      slug: slug,
      label: RactorTestSupport.request_label(spec),
      method: spec.fetch("method"),
      path: spec.fetch("path"),
      query: spec["query"].to_s,
      requested_path: requested_path(spec),
      expected_statuses: RactorTestSupport.expected_statuses(spec),
      status: response&.fetch(:status, nil),
      body_length: response&.fetch(:body_length, nil),
      location: response&.fetch(:location, nil),
      passed: error.nil?,
      error: RactorTestSupport.format_error(error),
      total_warnings: groups.sum { |group| group.fetch(:count) },
      unique_warning_groups: groups.size,
      warning_groups: groups,
    }
  ensure
    RactorIsolationWarnings.clear
  end

  def skipped_requests(specs, error)
    existing_slugs = {}
    specs.map do |spec|
      {
        slug: RactorTestSupport.request_slug(spec, existing_slugs: existing_slugs),
        label: RactorTestSupport.request_label(spec),
        method: spec.fetch("method"),
        path: spec.fetch("path"),
        query: spec["query"].to_s,
        requested_path: requested_path(spec),
        expected_statuses: RactorTestSupport.expected_statuses(spec),
        status: nil,
        body_length: nil,
        location: nil,
        passed: false,
        error: RactorTestSupport.format_error(error),
        total_warnings: 0,
        unique_warning_groups: 0,
        warning_groups: [],
      }
    end
  end

  def warning_groups_from_capture
    backtraces = RactorIsolationWarnings.warning_backtraces
    RactorIsolationWarnings.grouped.map do |title, messages|
      first_message = messages.first.to_s
      backtrace = Array(backtraces[title])
      file, line = first_location(first_message, backtrace)

      {
        title: title,
        count: messages.size,
        first_message: first_message,
        first_file: file,
        first_line: line,
        backtrace: backtrace,
      }
    end.sort_by { |group| [-group.fetch(:count), group.fetch(:title)] }
  end

  def finalize_counts(result)
    result[:total_requests] = result[:requests].size
    result[:passed_requests] = result[:requests].count { |request| request[:passed] }
    result[:failed_requests] = result[:total_requests] - result[:passed_requests]
    result[:total_warnings] = result[:requests].sum { |request| request[:total_warnings].to_i }
    result[:warning_groups] = aggregate_warning_groups(result[:requests])
    result[:unique_warning_groups] = result[:warning_groups].size
    result
  end

  def aggregate_warning_groups(requests)
    aggregate = {}

    requests.each do |request|
      request.fetch(:warning_groups).each do |group|
        entry = aggregate[group.fetch(:title)] ||= {
          title: group.fetch(:title),
          count: 0,
          requests: [],
          first_request_slug: request.fetch(:slug),
          first_file: group[:first_file],
          first_line: group[:first_line],
          area: nil,
          first_message: group[:first_message],
          backtrace: group[:backtrace],
        }

        entry[:count] += group.fetch(:count)
        entry[:requests] << request.fetch(:slug) unless entry[:requests].include?(request.fetch(:slug))
        entry[:first_file] ||= group[:first_file]
        entry[:first_line] ||= group[:first_line]
        entry[:first_message] ||= group[:first_message]
        entry[:backtrace] = group[:backtrace] if Array(entry[:backtrace]).empty? && Array(group[:backtrace]).any?
      end
    end

    aggregate.values.sort_by { |group| [-group.fetch(:count), group.fetch(:title)] }
  end

  def base_result(started_at, total_requests)
    rails_source = lock_source_for("rails")
    rack_source = lock_source_for("rack")

    {
      generated_at: started_at.iso8601,
      app_sha: app_sha,
      workflow_run_number: ENV["GITHUB_RUN_NUMBER"],
      workflow_run_id: ENV["GITHUB_RUN_ID"],
      ruby_description: RUBY_DESCRIPTION,
      rails_version: defined?(Rails) ? Rails.version : nil,
      rails_source: rails_source[:source],
      rails_git_revision: rails_source[:revision],
      rack_version: rack_version,
      rack_source: rack_source[:source],
      rack_git_revision: rack_source[:revision],
      rails_env: defined?(Rails) ? Rails.env.to_s : ENV["RAILS_ENV"],
      ractorized: false,
      application_shareable: false,
      ractorize_error: nil,
      total_requests: total_requests,
      passed_requests: 0,
      failed_requests: 0,
      total_warnings: 0,
      unique_warning_groups: 0,
      requests: [],
      warning_groups: [],
    }
  end

  def app_sha
    sha = `git rev-parse HEAD 2>/dev/null`.strip
    sha.empty? ? nil : sha
  rescue StandardError
    nil
  end

  def rack_version
    if defined?(Rack)
      return Rack.release if Rack.respond_to?(:release)
      return Rack.version if Rack.respond_to?(:version)
    end

    Gem.loaded_specs["rack"]&.version&.to_s
  end

  def lock_source_for(gem_name)
    lock_path = File.expand_path("../Gemfile.lock", __dir__)
    return { source: nil, revision: nil } unless File.file?(lock_path)

    blocks = File.read(lock_path).split(/^GIT\n/).drop(1)
    blocks.each do |block|
      remote = block[/^  remote: (.+)$/, 1]
      revision = block[/^  revision: (.+)$/, 1]
      branch = block[/^  branch: (.+)$/, 1]
      specs = block.split(/^  specs:\n/, 2)[1].to_s
      next unless specs.match?(/^    #{Regexp.escape(gem_name)} \(/)

      source = [remote, branch && "branch #{branch}", revision && "revision #{revision}"].compact.join(" ")
      return { source: source, revision: revision }
    end

    { source: Gem.loaded_specs[gem_name]&.full_gem_path, revision: nil }
  rescue StandardError
    { source: nil, revision: nil }
  end

  def requested_path(spec)
    query = spec["query"].to_s
    query.empty? ? spec.fetch("path") : "#{spec.fetch("path")}?#{query}"
  end

  def first_location(message, backtrace)
    ([message] + Array(backtrace)).each do |line|
      next unless line

      if line =~ /(?:^|\s)([^\s:\n][^:\n]*):(\d+):/
        return [Regexp.last_match(1), Regexp.last_match(2).to_i]
      end
    end

    [nil, nil]
  end
end
