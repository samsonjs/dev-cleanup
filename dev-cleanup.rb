#!/usr/bin/env ruby -w
# frozen_string_literal: true

#
# Frees disk space that Xcode, FlowDeck and agent scratch folders pile up and
# never give back: DerivedData and SwiftPM .build folders nobody has built into
# lately, old FlowDeck logs, Gradle and Homebrew caches, outdated device support
# files, and simulators that were made for one task and never booted again.
# When less than min_free_gb is free after that, it removes the least recently
# built DerivedData, sparing anything built in the last evict_after_hours.
#
#   ./dev-cleanup.rb             # dry run: list what would go and how big it is
#   ./dev-cleanup.rb --delete    # actually delete it
#   ./dev-cleanup.rb --install   # run --delete hourly with launchd
#   ./dev-cleanup.rb --uninstall
#
# Something counts as untouched when nothing in it, down to a few levels deep,
# was modified within its number of days. Anything a running process mentions
# in its arguments or has as its working directory is skipped, so an active
# build keeps its DerivedData. Simulators go when they're shut down, haven't
# been used in 14 days and have a custom name; ones named after their device
# type ("iPhone 17 Pro") stay, as do any the config's keep list matches.
#
# The defaults cover Xcode's and FlowDeck's DerivedData, FlowDeck's logs, and
# the Gradle and Homebrew caches. Add your own folders, or change the defaults,
# in ~/.config/dev-cleanup.yml:
#
#   simulator_days: 14
#   min_free_gb: 150       # 0 turns off removing builds for space
#   evict_after_hours: 6
#   keep_simulators:       # names or UDIDs to spare, globs allowed
#     - ci-golden-*
#   directories:
#     - path: ~/.claude-scratchpad
#       days: 7                # remove top-level entries untouched this long
#       derived_data_days: 3   # and build folders found inside, sooner
#     - path: ~/Developer
#       derived_data_days: 3   # build folders only, nothing else goes
#     - path: ~/Library/Developer/Xcode/DerivedData
#       days: 5
#
# --install copies this script to ~/Library/Application Support/dev-cleanup,
# so the agent doesn't depend on this checkout, and runs it with the Ruby that
# ran the install. Re-run --install after updating the script or removing that
# Ruby. Each run appends to ~/Library/Logs/dev-cleanup.log.

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"
require "yaml"

module DevCleanup
  DAY = 86_400
  MAX_DEPTH = 4
  HOUR = 3_600
  GB = 1024**3
  DEFAULT_SIMULATOR_DAYS = 14
  DEFAULT_MIN_FREE_GB = 150
  DEFAULT_EVICT_AFTER_HOURS = 6
  DEFAULT_DIRECTORIES = [
    {"path" => "~/Library/Developer/Xcode/DerivedData", "days" => 3},
    {"path" => "~/Library/Developer/FlowDeck/DerivedData", "days" => 3},
    {"path" => "~/.flowdeck/logs", "days" => 3},
    {"path" => "~/.gradle/caches", "days" => 14},
    {"path" => "~/.gradle/wrapper/dists", "days" => 14},
    {"path" => "~/Library/Caches/Homebrew/downloads", "days" => 14},
  ].freeze
  CONFIG_PATH = File.join(Dir.home, ".config", "dev-cleanup.yml")

  LABEL = "net.samhuri.dev-cleanup"
  INSTALL_DIR = File.join(Dir.home, "Library", "Application Support", "dev-cleanup")
  PLIST_PATH = File.join(Dir.home, "Library", "LaunchAgents", "#{LABEL}.plist")
  LOG_PATH = File.join(Dir.home, "Library", "Logs", "dev-cleanup.log")

  Target = Data.define(:path, :days, :derived_data_days)
  Candidate = Data.define(:path, :days)
  Build = Data.define(:path, :touched_at)
  Simulator = Data.define(:udid, :name, :bytes, :last_used_at)

  Config = Data.define(
    :targets, :simulator_days, :keep_simulators, :min_free_gb, :evict_after_hours,
  ) do
    def initialize(
      targets:, simulator_days:, keep_simulators: [], min_free_gb: DEFAULT_MIN_FREE_GB,
      evict_after_hours: DEFAULT_EVICT_AFTER_HOURS
    )
      super
    end

    def self.load(path, home: Dir.home)
      settings = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      targets = {}
      (DEFAULT_DIRECTORIES + Array(settings["directories"])).each do |entry|
        target = target_from(entry, home:)
        targets[target.path] = target
      end
      new(
        targets: targets.values,
        simulator_days: positive_days(settings.fetch("simulator_days", DEFAULT_SIMULATOR_DAYS)),
        keep_simulators: Array(settings["keep_simulators"]).map { it.to_s },
        min_free_gb: at_least(0, settings.fetch("min_free_gb", DEFAULT_MIN_FREE_GB), "min_free_gb"),
        evict_after_hours: at_least(
          1, settings.fetch("evict_after_hours", DEFAULT_EVICT_AFTER_HOURS), "evict_after_hours",
        ),
      )
    end

    def self.target_from(entry, home:)
      path = entry.fetch("path")
      unless entry["days"] || entry["derived_data_days"]
        raise ArgumentError, "#{path} needs days, derived_data_days or both"
      end

      Target.new(
        path: path.sub(%r{\A~(?=/|\z)}, home),
        days: entry["days"]&.then { positive_days(it) },
        derived_data_days: entry["derived_data_days"]&.then { positive_days(it) },
      )
    end

    def self.positive_days(value) = at_least(1, value, "days")

    def self.at_least(min, value, name)
      number = Integer(value)
      raise ArgumentError, "#{name} must be at least #{min}, got #{value}" if number < min

      number
    end
  end

  module_function

  def touched_since?(path, cutoff, depth: 0)
    stat = File.lstat(path)
    return true if stat.mtime > cutoff
    return false unless stat.directory? && depth < MAX_DEPTH

    Dir.each_child(path).any? { touched_since?(File.join(path, it), cutoff, depth: depth + 1) }
  rescue Errno::ENOENT
    false
  rescue SystemCallError
    true
  end

  def derived_data?(path)
    File.directory?(File.join(path, "ModuleCache.noindex")) ||
      File.directory?(File.join(path, "Build", "Intermediates.noindex"))
  end

  def swiftpm_build?(path)
    File.basename(path) == ".build" && File.file?(File.join(File.dirname(path), "Package.swift"))
  end

  def build_folder?(path) = derived_data?(path) || swiftpm_build?(path)

  def stale_children(target, now:)
    return [] unless target.days && File.directory?(target.path)

    cutoff = now - (target.days * DAY)
    Dir.children(target.path).sort.filter_map do |name|
      path = File.join(target.path, name)
      next if File.symlink?(path) || touched_since?(path, cutoff)

      Candidate.new(path:, days: target.days)
    end
  end

  def stale_derived_data(target, now:)
    return [] unless target.derived_data_days && File.directory?(target.path)

    cutoff = now - (target.derived_data_days * DAY)
    derived_data_within(target.path, depth: 1).filter_map do |path|
      Candidate.new(path:, days: target.derived_data_days) unless touched_since?(path, cutoff)
    end
  end

  def derived_data_within(dir, depth:)
    return [] if depth > 3

    Dir.children(dir).sort.flat_map do |name|
      path = File.join(dir, name)
      next [] if File.symlink?(path) || !File.directory?(path)

      build_folder?(path) ? [path] : derived_data_within(path, depth: depth + 1)
    end
  rescue SystemCallError
    []
  end

  def candidates_for(target, now:)
    children = stale_children(target, now:)
    nested = stale_derived_data(target, now:).reject do |candidate|
      children.any? { candidate.path.start_with?("#{it.path}/") }
    end
    children + nested
  end

  def last_touched_at(path, now:, depth: 0)
    stat = File.lstat(path)
    return stat.mtime unless stat.directory? && depth < MAX_DEPTH

    times = Dir.each_child(path).map do
      last_touched_at(File.join(path, it), now:, depth: depth + 1)
    end
    times.compact.push(stat.mtime).max
  rescue Errno::ENOENT
    nil
  rescue SystemCallError
    now
  end

  def evictable_builds(targets, now:, evict_after_hours:)
    cutoff = now - (evict_after_hours * HOUR)
    paths = targets.flat_map { derived_data_within(it.path, depth: 1) }.uniq
    builds = paths.filter_map do |path|
      touched_at = last_touched_at(path, now:)
      Build.new(path:, touched_at:) if touched_at && touched_at <= cutoff
    end
    builds.sort_by(&:touched_at)
  end

  def free_bytes(path)
    capture("df", "-kP", path).lines[1].split[3].to_i * 1024
  end

  def device_support_roots
    Dir.glob(File.join(Dir.home, "Library", "Developer", "Xcode", "* DeviceSupport"))
  end

  def stale_device_support(root)
    versioned = Dir.children(root).filter_map do |name|
      match = name.match(/\A(?<model>\S+) (?<version>\d+(?:\.\d+)*) \(/)
      [File.join(root, name), match[:model], Gem::Version.new(match[:version])] if match
    end
    versioned.group_by { it[1] }.values.flat_map do |entries|
      entries.sort_by { it[2] }[...-1].map(&:first)
    end
  rescue SystemCallError
    []
  end

  def in_use?(path, busy)
    pattern = %r{#{Regexp.escape(path)}(?=[/\s'"]|\z)}
    busy.any? { it.match?(pattern) }
  end

  # launchd leaves LANG unset, so Ruby would otherwise read command output as
  # US-ASCII and choke on the first non-ASCII byte.
  def capture(*command)
    out, = Open3.capture2(*command, err: File::NULL)
    out.force_encoding(Encoding::UTF_8).scrub
  end

  def busy_paths
    args = capture("ps", "-axww", "-o", "args=").lines(chomp: true)
    cwds = capture("lsof", "-nP", "-d", "cwd", "-Fn").lines(chomp: true)
    args + cwds.filter_map { it[1..] if it.start_with?("n") }
  end

  def kept_simulator?(device, keep)
    keep.any? do |pattern|
      File.fnmatch?(pattern, device["name"], File::FNM_CASEFOLD) ||
        File.fnmatch?(pattern, device["udid"], File::FNM_CASEFOLD)
    end
  end

  def stale_simulators(devices:, device_types:, days:, now:, keep: [])
    stock_names = device_types.fetch("devicetypes").map { it["name"] }
    cutoff = now - (days * DAY)
    devices.fetch("devices").values.flatten.filter_map do |device|
      next unless device["isAvailable"] && device["state"] == "Shutdown" && device["lastUsedAt"]
      next if stock_names.include?(device["name"]) || kept_simulator?(device, keep)

      last_used_at = Time.iso8601(device["lastUsedAt"])
      next if last_used_at > cutoff

      Simulator.new(
        udid: device["udid"], name: device["name"], bytes: device["dataPathSize"].to_i, last_used_at:,
      )
    end
  end

  def disk_bytes(path)
    capture("du", "-sk", path).to_i * 1024
  end

  def format_bytes(bytes)
    if bytes >= 1024**3
      format("%.1f GB", bytes.fdiv(1024**3))
    else
      format("%.0f MB", bytes.fdiv(1024**2))
    end
  end

  class Cleaner
    attr_reader :config, :delete, :simulators, :out, :now

    def initialize(
      config:, delete:, busy: nil, free_bytes: nil, disk_bytes: nil, device_support_roots: nil,
      simulators: true, out: $stdout, now: Time.now
    )
      @config = config
      @delete = delete
      @busy = busy
      @free_bytes = free_bytes
      @disk_bytes = disk_bytes || DevCleanup.method(:disk_bytes)
      @device_support_roots = device_support_roots
      @simulators = simulators
      @out = out
      @now = now
      @handled = []
    end

    def run
      out.puts "#{delete ? "Cleaning up" : "Dry run"} at #{now.iso8601}"
      free_at_start = free_bytes
      total = config.targets.sum { clean_target(it) }
      total += device_support_roots.sum { clean_device_support(it) }
      total += clean_simulators if simulators
      total += evict((config.min_free_gb * GB) - free_at_start - total)
      out.puts "#{delete ? "Freed" : "Would free"} #{DevCleanup.format_bytes(total)}"
      total
    end

    private

    def busy = @busy ||= DevCleanup.busy_paths

    def free_bytes = @free_bytes ||= DevCleanup.free_bytes(Dir.home)

    def disk_bytes(path) = @disk_bytes.call(path)

    def device_support_roots = @device_support_roots ||= DevCleanup.device_support_roots

    def clean_target(target)
      DevCleanup.candidates_for(target, now:).sum { remove(it.path) }
    end

    def clean_device_support(root)
      DevCleanup.stale_device_support(root).sum { remove(it) }
    end

    def evict(shortfall)
      return 0 unless shortfall.positive?

      out.puts "  #{DevCleanup.format_bytes(shortfall)} short of #{config.min_free_gb} GB free, " \
        "removing the least recently built DerivedData"
      builds = DevCleanup.evictable_builds(
        config.targets, now:, evict_after_hours: config.evict_after_hours,
      )
      freed = 0
      builds.each do |build|
        break if freed >= shortfall
        next if handled?(build.path)

        built = build.touched_at.localtime.strftime("%Y-%m-%d %H:%M")
        freed += remove(build.path, note: "built #{built}")
      end
      freed
    end

    def handled?(path)
      @handled.any? { path == it || path.start_with?("#{it}/") }
    end

    def remove(path, note: nil)
      @handled << path
      if DevCleanup.in_use?(path, busy)
        out.puts "  skipped (in use)  #{path}"
        return 0
      end

      bytes = disk_bytes(path)
      out.puts "  #{DevCleanup.format_bytes(bytes).rjust(9)}  #{path}#{" (#{note})" if note}"
      return bytes unless delete

      system("/bin/rm", "-rf", path)
      return bytes unless File.exist?(path)

      out.puts "  couldn't remove all of #{path}"
      bytes - disk_bytes(path)
    end

    def clean_simulators
      system("xcrun", "simctl", "delete", "unavailable") if delete
      devices = simctl_json("devices")
      device_types = simctl_json("devicetypes")
      stale = DevCleanup.stale_simulators(
        devices:, device_types:, days: config.simulator_days,
        keep: config.keep_simulators, now:,
      )
      stale.sum do |sim|
        last_used = sim.last_used_at.localtime.strftime("%Y-%m-%d")
        out.puts "  #{DevCleanup.format_bytes(sim.bytes).rjust(9)}  simulator #{sim.name} " \
          "(#{sim.udid}), last used #{last_used}"
        system("xcrun", "simctl", "delete", sim.udid) if delete
        sim.bytes
      end
    rescue Errno::ENOENT, JSON::ParserError
      0
    end

    def simctl_json(kind) = JSON.parse(DevCleanup.capture("xcrun", "simctl", "list", kind, "-j"))
  end

  def install
    FileUtils.mkdir_p(INSTALL_DIR)
    script = File.join(INSTALL_DIR, "dev-cleanup.rb")
    FileUtils.cp(__FILE__, script)
    FileUtils.mkdir_p(File.dirname(PLIST_PATH))
    File.write(PLIST_PATH, JSON.generate(launchd_job(script:)))
    system("plutil", "-convert", "xml1", PLIST_PATH, exception: true)

    domain = "gui/#{Process.uid}"
    system("launchctl", "bootout", "#{domain}/#{LABEL}", err: File::NULL)
    system("launchctl", "bootstrap", domain, PLIST_PATH, exception: true)
    puts "Installed #{LABEL}: runs hourly, logs to #{LOG_PATH}"
  end

  def launchd_job(script:)
    {
      "Label" => LABEL,
      "ProgramArguments" => [RbConfig.ruby, script, "--delete"],
      "StartCalendarInterval" => {"Minute" => 0},
      "StandardOutPath" => LOG_PATH,
      "StandardErrorPath" => LOG_PATH,
      "EnvironmentVariables" => {"PATH" => "/usr/bin:/bin:/usr/sbin:/sbin"},
      "ProcessType" => "Background",
      "LowPriorityIO" => true,
      "Nice" => 10,
    }
  end

  def uninstall
    system("launchctl", "bootout", "gui/#{Process.uid}/#{LABEL}", err: File::NULL)
    FileUtils.rm_f(PLIST_PATH)
    FileUtils.rm_rf(INSTALL_DIR)
    puts "Uninstalled #{LABEL}"
  end

  def main(argv)
    options = {delete: false, simulators: true, config: CONFIG_PATH}
    action = :run
    OptionParser.new do |parser|
      parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
      parser.on("--delete", "Delete what a dry run lists") { options[:delete] = true }
      parser.on("--no-simulators", "Leave simulators alone") { options[:simulators] = false }
      parser.on("--config PATH", "Config file (default: #{CONFIG_PATH})") { options[:config] = it }
      parser.on("--install", "Run --delete hourly with launchd") { action = :install }
      parser.on("--uninstall", "Remove the launchd agent") { action = :uninstall }
    end.parse!(argv)

    case action
    when :install then install
    when :uninstall then uninstall
    else
      config = Config.load(options[:config])
      Cleaner.new(config:, delete: options[:delete], simulators: options[:simulators]).run
    end
  end
end

DevCleanup.main(ARGV) if $PROGRAM_NAME == __FILE__
