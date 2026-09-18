# frozen_string_literal: true

# ---------------------------------------------------------------------------
# 0. Validate options
#
# Solid gems are currently not compatible with Ractors.
# ---------------------------------------------------------------------------

SKIP_SOLID_ERROR = <<~RUBY
  Solid gems are not compatible with Ractors. Please use the --skip-solid option
RUBY

raise SKIP_SOLID_ERROR unless options[:skip_solid]

# ---------------------------------------------------------------------------
# 1. Pin unreleased, Ractor-safe gem sources.
#
# These live on branches/main that carry Ractor-safety fixes not yet released
# to RubyGems. We drop whatever the generator wrote and re-add git sources.
# ---------------------------------------------------------------------------

RACTOR_GEM_SOURCES = {
  "rails"           => { github: "Shopify/rails", branch: "ar_ractorize_4" },
  "rack"            => { github: "rack/rack" },
  "propshaft"       => { github: "rails/propshaft" },
  "i18n"            => { github: "Shopify/i18n", branch: "ractor_support" },
  "useragent"       => { github: "Shopify/useragent", branch: "ec-frozen-strings" },
  "openssl"         => { github: "ruby/openssl" },
  "importmap-rails" => { github: "Shopify/importmap-rails", branch: "hm-ysktlmxtkzxnzmot" },
}

RACTOR_GEM_SOURCES.each do |name, opts|
  gsub_file "Gemfile", /^\s*gem ["']#{Regexp.escape(name)}["'].*\n/, ""
end

append_to_file "Gemfile", <<~ERB

  # ---------------------------------------------------------------------------
  # Ractor-safe gem sources.
  #
  # These branches/mains carry Ractor-safety fixes that are not yet released to
  # RubyGems. Pin them until the fixes ship in a stable release.
  # ---------------------------------------------------------------------------

  #{RACTOR_GEM_SOURCES.map { |name, opts|
    args = opts.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
    %(gem "#{name}", #{args})
  }.join("\n")}
ERB

# ---------------------------------------------------------------------------
# 2. Ractor-safe production configuration.
#
# Injected just before the final `end` of the Rails.application.configure block
# in config/environments/production.rb.
# ---------------------------------------------------------------------------

RACTOR_PRODUCTION_CONFIG = <<-RUBY

  # Raise on any unshareable proc so boot-time callbacks that would leak non-shareable state are caught up front.
  ActiveSupport::Ractors.unshareable_proc_action = :raise

  # A Ractor-safe logger: TaggedLogging that works across Ractors.
  config.logger = ActiveSupport::TaggedLogging.ractor_logger(STDOUT)

  # Serve requests through the application only. Static file serving, the
  # default cache store, Action Cable, and the default Active Job adapter all
  # register non-shareable state; use Ractor-safe substitutes.
  config.cache_store = :null_store
  config.action_cable.mount_path = nil
  config.active_job.queue_adapter = :inline

  config.active_record.check_schema_cache_dump_version = false
RUBY

production_path = "config/environments/production.rb"
inject_into_file production_path, RACTOR_PRODUCTION_CONFIG, before: /^end\s*\z/

# ---------------------------------------------------------------------------
# 3. Always boot in production, on Cougar.
# ---------------------------------------------------------------------------

gsub_file "Gemfile", /^\s*gem ["']puma["'].*\n/, "gem \"cougar\"\n"

inject_into_file "config/boot.rb", after: /^ENV\["BUNDLE_GEMFILE"\].*\n/ do
  <<~RUBY
    ENV["RAILS_ENV"] = "production" # This app only runs in production.
    ENV["RACKUP_HANDLER"] ||= "cougar" # Serve with Cougar without passing `-u cougar`.
  RUBY
end

# ---------------------------------------------------------------------------
# 4. Call ractorize!
# ---------------------------------------------------------------------------


append_to_file "config.ru", <<~RUBY
  Rails.application.ractorize!
  require "i18n/ractorize"
RUBY
