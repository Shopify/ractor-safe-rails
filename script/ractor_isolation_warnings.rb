# frozen_string_literal: true

# Capture :ractor_isolation category warnings emitted by
# Ractor.check_isolation { ... }.
#
# The collector deliberately keeps its mutable state in globals initialized
# before any isolation checks run. Inside Ractor.check_isolation, captured local
# variables can look like cross-Ractor references; globals avoid that failure
# mode and a re-entrancy guard prevents recursive warning emission.

$ractor_isolation_warnings = []
$ractor_isolation_warning_backtraces = {}
$ractor_isolation_warnings_mutex = Mutex.new
$ractor_isolation_capture_backtrace = ENV["RACTOR_ISOLATION_CAPTURE_BACKTRACE"] == "1"

module IsolationWarningInterceptor
  BACKTRACE_LIMIT = 80

  def warn(msg, category: nil)
    if category == :ractor_isolation
      return if Thread.current[:in_isolation_warn]

      Thread.current[:in_isolation_warn] = true
      begin
        message = msg.to_s
        key = first_line_key(message)
        backtrace = nil

        if $ractor_isolation_capture_backtrace
          needs_backtrace = $ractor_isolation_warnings_mutex.synchronize do
            !$ractor_isolation_warning_backtraces.key?(key)
          end
          backtrace = capture_backtrace if needs_backtrace
        end

        $ractor_isolation_warnings_mutex.synchronize do
          $ractor_isolation_warnings << message
          $ractor_isolation_warning_backtraces[key] ||= backtrace if backtrace
        end
      ensure
        Thread.current[:in_isolation_warn] = false
      end
      return
    end

    super
  end

  private
    def capture_backtrace
      own_file = __FILE__
      raw = Array(caller_locations(1, BACKTRACE_LIMIT)).map(&:to_s)
      filtered = raw.reject { |line| line.start_with?(own_file) }
      filtered.empty? ? raw : filtered
    end

    def first_line_key(message)
      line = message.lines.first.to_s.chomp
      line.sub(/\A.*?: warning: /, "").strip
    end
end

Warning.singleton_class.prepend(IsolationWarningInterceptor)

# RailsStrictWarnings can itself emit isolation warnings while formatting a
# warning. Guard it, when present, to avoid infinitely recursive Warning.warn.
module RailsStrictWarningsReentrancyGuard
  def warn(*, **, &)
    return if Thread.current[:in_strict_warnings_warn]

    Thread.current[:in_strict_warnings_warn] = true
    begin
      super
    ensure
      Thread.current[:in_strict_warnings_warn] = false
    end
  end
end

install_strict_warnings_guard = lambda do
  return unless defined?(RailsStrictWarnings)
  return if RailsStrictWarnings.include?(RailsStrictWarningsReentrancyGuard)

  RailsStrictWarnings.prepend(RailsStrictWarningsReentrancyGuard)
end

install_strict_warnings_guard.call

unless defined?(RailsStrictWarnings)
  install = install_strict_warnings_guard
  watcher = Module.new do
    define_method(:const_added) do |name|
      super(name)
      install.call if name == :RailsStrictWarnings
    end
  end
  Object.singleton_class.prepend(watcher)
end

module RactorIsolationWarnings
  extend self

  def run(&block)
    raise "Ractor.check_isolation is not available in #{RUBY_DESCRIPTION}" unless Ractor.respond_to?(:check_isolation)

    Ractor.check_isolation(&block)
  end

  def warnings
    $ractor_isolation_warnings_mutex.synchronize do
      $ractor_isolation_warnings.dup
    end
  end

  def warning_backtraces
    $ractor_isolation_warnings_mutex.synchronize do
      $ractor_isolation_warning_backtraces.transform_values(&:dup)
    end
  end

  def clear
    $ractor_isolation_warnings_mutex.synchronize do
      $ractor_isolation_warnings.clear
      $ractor_isolation_warning_backtraces.clear
    end
  end

  def grouped
    warnings.group_by { |msg| first_line_key(msg) }
  end

  private

  def first_line_key(msg)
    line = msg.lines.first.to_s.chomp
    line.sub(/\A.*?: warning: /, "").strip
  end
end
