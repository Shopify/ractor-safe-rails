#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "erb"
require "fileutils"
require "json"
require "time"

site_root, run_number, run_id, run_url, results_json_path, dump_path = ARGV
unless ARGV.size == 6
  abort "usage: render_isolation_site.rb <site-root> <run-number> <run-id> <run-url> <results.json> <dump.txt>"
end
abort "results.json missing: #{results_json_path}" unless File.file?(results_json_path)
abort "dump.txt missing: #{dump_path}" unless File.file?(dump_path)

TEMPLATE_ROOT = File.expand_path("isolation_site_templates", __dir__)

# ── helpers available to templates ─────────────────────────────────────
def h(value)
  CGI.escapeHTML(value.to_s)
end

def short_sha(value)
  text = value.to_s
  text.empty? ? "unknown" : text[0, 12]
end

def with_commas(value)
  value.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

def display_file(file)
  file.to_s
    .sub(%r{^.*/ractor-safe-rails/}, "")
    .sub(%r{^.*/rails/}, "rails/")
    .sub(%r{^.*/rack/}, "rack/")
    .sub(%r{^.*/ruby-src/}, "ruby-src/")
    .sub(%r{^.*/ruby-install/}, "ruby-install/")
    .sub(%r{^.*/gems/}, "gems/")
    .sub(%r{^.*/bundler/gems/}, "gems/")
end

def extract_location(line)
  return unless line =~ /(?:^|\s)([^\s:\n][^:\n]*):(\d+):/

  [Regexp.last_match(1), Regexp.last_match(2).to_i]
end

def classify(file)
  return "unknown" if file.nil? || file.empty?

  normalized = file.to_s
  case normalized
  when %r{(^|/)app/controllers/} then "app:controllers"
  when %r{(^|/)app/models/}      then "app:models"
  when %r{(^|/)app/views/}       then "app:views"
  when %r{(^|/)app/helpers/}     then "app:helpers"
  when %r{(^|/)config/}          then "app:config"
  when %r{(^|/)actionpack/}      then "rails:actionpack"
  when %r{(^|/)activerecord/}    then "rails:activerecord"
  when %r{(^|/)actionview/}      then "rails:actionview"
  when %r{(^|/)activesupport/}   then "rails:activesupport"
  when %r{(^|/)railties/}        then "rails:railties"
  when %r{(^|/)rails/([^/]+)/}   then "rails:#{Regexp.last_match(2)}"
  when %r{(^|/)rack/}            then "gem:rack"
  when %r{(^|/)gems/([^/]+?)-\d} then "gem:#{Regexp.last_match(2)}"
  when %r{(^|/)ruby-src/}, %r{(^|/)ruby-install/}, %r{(^|/)ruby/[0-9.]+/} then "ruby-stdlib"
  else "other"
  end
end

def warning_group_file_and_line(group)
  file = group["first_file"]
  line = group["first_line"]
  return [file, line] if file && !file.empty?

  Array(group["backtrace"]).each do |frame|
    location = extract_location(frame)
    return location if location
  end

  [nil, nil]
end

def enriched_warning_groups(result)
  Array(result["warning_groups"]).map do |group|
    file, line = warning_group_file_and_line(group)
    group.merge(
      "display_file" => display_file(file),
      "first_file" => file,
      "first_line" => line,
      "area" => group["area"] || classify(file),
    )
  end
end

def area_summaries(groups)
  areas = Hash.new { |hash, key| hash[key] = { "area" => key, "count" => 0, "unique" => 0 } }
  groups.each do |group|
    area = group["area"] || "unknown"
    areas[area]["count"] += group["count"].to_i
    areas[area]["unique"] += 1
  end
  areas.values.sort_by { |area| [-area["count"], area["area"]] }
end

def render_template(name)
  path = File.join(TEMPLATE_ROOT, name)
  ERB.new(File.read(path), trim_mode: "-").result(binding)
end

def render_page(template_name, output_path, title:, asset_prefix:, **assigns)
  assigns.each { |name, value| instance_variable_set("@#{name}", value) }
  @title = title
  @asset_prefix = asset_prefix
  @content = render_template(template_name)
  html = render_template("layout.html.erb")
  FileUtils.mkdir_p(File.dirname(output_path))
  File.write(output_path, html)
ensure
  assigns.each_key { |name| remove_instance_variable("@#{name}") if instance_variable_defined?("@#{name}") }
end

def run_sort_key(meta)
  generated = Time.iso8601(meta["generated_at"]).to_i rescue 0
  number = meta["run_number"].to_s =~ /\A\d+\z/ ? meta["run_number"].to_i : 0
  [generated, number]
end

result = JSON.parse(File.read(results_json_path))
run_slug = run_number.to_s.gsub(/[^A-Za-z0-9._-]+/, "_")
run_dir = File.join(site_root, "runs", run_slug)
FileUtils.mkdir_p(run_dir)

FileUtils.cp(dump_path, File.join(run_dir, "dump.txt"))

metadata = {
  "run_number" => run_number.to_s,
  "run_id" => run_id.to_s,
  "run_url" => run_url.to_s,
  "run_path" => "runs/#{run_slug}/",
  "generated_at" => result["generated_at"],
  "published_at" => Time.now.utc.iso8601,
  "app_sha" => result["app_sha"],
  "ruby_description" => result["ruby_description"],
  "rails_version" => result["rails_version"],
  "rails_source" => result["rails_source"],
  "rack_version" => result["rack_version"],
  "rack_source" => result["rack_source"],
  "rails_env" => result["rails_env"],
  "ractorized" => result["ractorized"],
  "application_shareable" => result["application_shareable"],
  "total_requests" => result["total_requests"],
  "passed_requests" => result["passed_requests"],
  "failed_requests" => result["failed_requests"],
  "total_warnings" => result["total_warnings"],
  "unique_warning_groups" => result["unique_warning_groups"],
}
File.write(File.join(run_dir, "meta.json"), JSON.pretty_generate(metadata) << "\n")

FileUtils.mkdir_p(File.join(site_root, "assets"))
FileUtils.cp(File.join(TEMPLATE_ROOT, "site.css"), File.join(site_root, "assets", "site.css"))

warning_groups = enriched_warning_groups(result)
areas = area_summaries(warning_groups)
render_page(
  "run.html.erb",
  File.join(run_dir, "index.html"),
  title: "Ractor isolation sweep ##{run_number}",
  asset_prefix: "../..",
  run: metadata,
  result: result,
  requests: Array(result["requests"]),
  warning_groups: warning_groups,
  areas: areas,
)

runs = Dir.glob(File.join(site_root, "runs", "*", "meta.json")).filter_map do |path|
  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end.sort_by { |meta| run_sort_key(meta) }.reverse

render_page(
  "index.html.erb",
  File.join(site_root, "index.html"),
  title: "Ractor isolation sweeps",
  asset_prefix: ".",
  runs: runs,
)

# Keep the GitHub Pages root discoverable.
docs_root = File.expand_path("..", site_root)
FileUtils.mkdir_p(docs_root)
File.write(File.join(docs_root, "index.html"), render_template("docs_index.html.erb"))
