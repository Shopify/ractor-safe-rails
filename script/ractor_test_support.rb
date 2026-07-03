# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "production"
ENV["SECRET_KEY_BASE_DUMMY"] ||= "1"

Ractor.warn_frozen_error = true if defined?(Ractor) && Ractor.respond_to?(:warn_frozen_error=)

require "erb"
require "stringio"
require "uri"
require "yaml"

module RactorTestSupport
  USER_AGENT = "RactorTest"

  extend self

  def boot_app!
    require_relative "../config/environment"
    ActionController::Base.allow_forgery_protection = false
    Rails.application
  end

  def prepare_database!
    boot_app! unless defined?(Rails)

    unless ActiveRecord::Base.connection.data_source_exists?("posts")
      puts "Loading database schema..." if verbose?
      ActiveRecord::Schema.verbose = false
      load Rails.root.join("db/schema.rb")
    end
  end

  def seed_request_data!
    boot_app! unless defined?(Rails)

    puts "Resetting database..." if verbose?
    Post.delete_all
    seed_post = Post.create!(body: "Seed post body from Ractor test")
    delete_post = Post.create!(body: "Delete me from Ractor test")
    puts "Database seeded." if verbose?

    {
      seed_post_id: seed_post.id,
      delete_post_id: delete_post.id,
    }
  end

  def load_request_specs(context)
    template = File.read(File.expand_path("requests.yml.erb", __dir__))
    seed_post_id = context.fetch(:seed_post_id)
    delete_post_id = context.fetch(:delete_post_id)

    YAML.safe_load(
      ERB.new(template).result(binding),
      permitted_classes: [Symbol],
      aliases: true,
    ).freeze
  end

  def build_env(spec)
    body = spec["params"] ? URI.encode_www_form(spec["params"]) : ""

    {
      "REQUEST_METHOD" => spec.fetch("method"),
      "SCRIPT_NAME" => "",
      "PATH_INFO" => spec.fetch("path"),
      "QUERY_STRING" => spec["query"] || "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "HTTP_HOST" => "localhost:3000",
      "HTTP_ACCEPT" => "text/html",
      "HTTP_USER_AGENT" => USER_AGENT,
      "CONTENT_TYPE" => spec["params"] ? "application/x-www-form-urlencoded" : nil,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.version" => [1, 6],
      "rack.multithread" => true,
      "rack.multiprocess" => false,
      "rack.run_once" => false,
      "rack.url_scheme" => "http",
      "rack.body" => body,
    }.merge(spec["headers"] || {}).compact
  end

  def perform_request(app, env)
    request_env = env.dup
    request_env["rack.input"] = StringIO.new(request_env.delete("rack.body") || "")
    request_env["rack.errors"] = StringIO.new
    request_env["action_dispatch.show_exceptions"] = :none

    status, headers, body = app.call(request_env)
    response_body = +""
    body.each { |part| response_body << part }

    {
      status: status,
      headers: headers,
      body: response_body,
      location: headers["location"] || headers["Location"],
      body_length: response_body.bytesize,
    }
  ensure
    body&.close if body.respond_to?(:close)
  end

  def validate_response!(spec, response)
    expected_statuses = expected_statuses(spec)
    unless expected_statuses.include?(response.fetch(:status))
      raise RuntimeError, "Expected #{expected_statuses.join('/')}, got #{response.fetch(:status)}"
    end

    missing = Array(spec["body_includes"]).compact.reject { |text| response.fetch(:body).include?(text) }
    unless missing.empty?
      raise RuntimeError, "Response body missing #{missing.inspect}; got #{response.fetch(:body).inspect[0..300]}"
    end

    true
  end

  def expected_statuses(spec)
    Array(spec["expect"])
  end

  def request_label(spec)
    label = "#{spec.fetch("method")} #{spec.fetch("path")}"
    query = spec["query"]
    label += " (#{query})" if query && !query.empty?
    label
  end

  def request_slug(spec, existing_slugs: nil)
    normalized_path = spec.fetch("path").gsub(%r{/\d+(?=[/.]|\z)}, "/id")
    raw = [spec.fetch("method"), normalized_path, spec["query"]].compact.join(" ")
    base = raw.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    base = "request" if base.empty?

    slug = base
    suffix = 2
    while slug_used?(existing_slugs, slug)
      slug = "#{base}_#{suffix}"
      suffix += 1
    end

    record_slug(existing_slugs, slug)
    slug
  end

  def format_error(error)
    return nil unless error

    {
      class: error.class.name,
      message: error.message,
      backtrace: Array(error.backtrace),
    }
  end

  def format_error_report(error, limit: nil)
    return "" unless error

    backtrace = Array(error.backtrace)
    backtrace = backtrace.first(limit) if limit
    (["#{error.class}: #{error.message}"] + backtrace.map { |line| "  #{line}" }).join("\n")
  end

  def with_verbosity(enabled)
    previous = Thread.current[:ractor_test_support_verbose]
    Thread.current[:ractor_test_support_verbose] = enabled
    yield
  ensure
    Thread.current[:ractor_test_support_verbose] = previous
  end

  def verbose?
    Thread.current[:ractor_test_support_verbose] != false
  end

  private

  def slug_used?(existing_slugs, slug)
    return false unless existing_slugs
    return existing_slugs.key?(slug) if existing_slugs.respond_to?(:key?)
    return existing_slugs.include?(slug) if existing_slugs.respond_to?(:include?)

    false
  end

  def record_slug(existing_slugs, slug)
    return unless existing_slugs

    if existing_slugs.respond_to?(:[]=)
      existing_slugs[slug] = true
    elsif existing_slugs.respond_to?(:<<)
      existing_slugs << slug
    end
  end
end
