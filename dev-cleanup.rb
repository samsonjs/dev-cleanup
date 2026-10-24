#!/usr/bin/env ruby -w
# frozen_string_literal: true

#
# Frees disk space that Xcode, FlowDeck and agent scratch folders pile up and
# never give back: DerivedData nobody has built into lately, old FlowDeck logs,
# and simulators that were made for one task and never booted again.
#
#   ./dev-cleanup.rb             # dry run: list what would go and how big it is
#   ./dev-cleanup.rb --delete    # actually delete it
#   ./dev-cleanup.rb --install   # run --delete daily at 04:00 with launchd
#   ./dev-cleanup.rb --uninstall
#
# Something counts as untouched when nothing in it, down to a few levels deep,
# was modified within its number of days. Anything a running process mentions
# in its arguments or has as its working directory is skipped, so an active
# build keeps its DerivedData. Simulators go when they're shut down, haven't
# been used in 14 days and have a custom name; ones named after their device
# type ("iPhone 17 Pro") stay, as do any the config's keep list matches.
#
# The defaults cover Xcode's and FlowDeck's DerivedData and FlowDeck's logs.
# Add your own folders, or change the defaults, in ~/.config/dev-cleanup.yml:
#
#   simulator_days: 14
#   keep_simulators:       # names or UDIDs to spare, globs allowed
#     - ci-golden-*
#   directories:
#     - path: ~/.claude-scratchpad
#       days: 7                # remove top-level entries untouched this long
#       derived_data_days: 3   # and DerivedData folders found inside, sooner
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
  DEFAULT_SIMULATOR_DAYS = 14
  DEFAULT_DIRECTORIES = [
    {"path" => "~/Library/Developer/Xcode/DerivedData", "days" => 3},
    {"path" => "~/Library/Developer/FlowDeck/DerivedData", "days" => 3},
    {"path" => "~/.flowdeck/logs", "days" => 3},
  ].freeze
  CONFIG_PATH = File.join(Dir.home, ".config", "dev-cleanup.yml")

  LABEL = "net.samhuri.dev-cleanup"
  INSTALL_DIR = File.join(Dir.home, "Library", "Application Support", "dev-cleanup")
  PLIST_PATH = File.join(Dir.home, "Library", "LaunchAgents", "#{LABEL}.plist")
  LOG_PATH = File.join(Dir.home, "Library", "Logs", "dev-cleanup.log")

  Target = Data.define(:path, :days, :derived_data_days)
  Candidate = Data.define(:path, :days)
  Simulator = Data.define(:udid, :name, :bytes, :last_used_at)

  Config = Data.define(:targets, :simulator_days, :keep_simulators) do
    def initialize(targets:, simulator_days:, keep_simulators: [])
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
      )
    end

    def self.target_from(entry, home:)
      Target.new(
        path: entry.fetch("path").sub(%r{\A~(?=/|\z)}, home),
        days: positive_days(entry.fetch("days")),
        derived_data_days: entry["derived_data_days"]&.then { positive_days(it) },
      )
    end

    def self.positive_days(value)
      days = Integer(value)
      raise ArgumentError, "days must be at least 1, got #{value}" if days < 1

      days
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

  def stale_children(target, now:)
    return [] unless File.directory?(target.path)

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

      derived_data?(path) ? [path] : derived_data_within(path, depth: depth + 1)
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

    def initialize(config:, delete:, busy: nil, simulators: true, out: $stdout, now: Time.now)
      @config = config
      @delete = delete
      @busy = busy
      @simulators = simulators
      @out = out
      @now = now
    end

    def run
      out.puts "#{delete ? "Cleaning up" : "Dry run"} at #{now.iso8601}"
      total = config.targets.sum { clean_target(it) }
      total += clean_simulators if simulators
      out.puts "#{delete ? "Freed" : "Would free"} #{DevCleanup.format_bytes(total)}"
      total
    end

    private

    def busy = @busy ||= DevCleanup.busy_paths

    def clean_target(target)
      DevCleanup.candidates_for(target, now:).sum do |candidate|
        if DevCleanup.in_use?(candidate.path, busy)
          out.puts "  skipped (in use)  #{candidate.path}"
          next 0
        end

        bytes = DevCleanup.disk_bytes(candidate.path)
        out.puts "  #{DevCleanup.format_bytes(bytes).rjust(9)}  #{candidate.path}"
        next bytes unless delete

        system("/bin/rm", "-rf", candidate.path)
        next bytes unless File.exist?(candidate.path)

        out.puts "  couldn't remove all of #{candidate.path}"
        bytes - DevCleanup.disk_bytes(candidate.path)
      end
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

  def install(hour:)
    FileUtils.mkdir_p(INSTALL_DIR)
    script = File.join(INSTALL_DIR, "dev-cleanup.rb")
    FileUtils.cp(__FILE__, script)
    FileUtils.mkdir_p(File.dirname(PLIST_PATH))
    File.write(PLIST_PATH, JSON.generate(launchd_job(script:, hour:)))
    system("plutil", "-convert", "xml1", PLIST_PATH, exception: true)

    domain = "gui/#{Process.uid}"
    system("launchctl", "bootout", "#{domain}/#{LABEL}", err: File::NULL)
    system("launchctl", "bootstrap", domain, PLIST_PATH, exception: true)
    puts "Installed #{LABEL}: runs daily at #{format("%02d:00", hour)}, logs to #{LOG_PATH}"
  end

  def launchd_job(script:, hour:)
    {
      "Label" => LABEL,
      "ProgramArguments" => [RbConfig.ruby, script, "--delete"],
      "StartCalendarInterval" => {"Hour" => hour, "Minute" => 0},
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
    options = {delete: false, simulators: true, config: CONFIG_PATH, hour: 4}
    action = :run
    OptionParser.new do |parser|
      parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"
      parser.on("--delete", "Delete what a dry run lists") { options[:delete] = true }
      parser.on("--no-simulators", "Leave simulators alone") { options[:simulators] = false }
      parser.on("--config PATH", "Config file (default: #{CONFIG_PATH})") { options[:config] = it }
      parser.on("--install", "Run --delete daily with launchd") { action = :install }
      parser.on("--hour HOUR", Integer, "Hour of the daily run (default: 4)") { options[:hour] = it }
      parser.on("--uninstall", "Remove the launchd agent") { action = :uninstall }
    end.parse!(argv)

    case action
    when :install then install(hour: options[:hour])
    when :uninstall then uninstall
    else
      config = Config.load(options[:config])
      Cleaner.new(config:, delete: options[:delete], simulators: options[:simulators]).run
    end
  end
end

DevCleanup.main(ARGV) if $PROGRAM_NAME == __FILE__
