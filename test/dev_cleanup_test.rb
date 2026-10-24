# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../dev-cleanup"

class DevCleanupTest < Minitest::Test
  NOW = Time.utc(2026, 10, 24, 12)
  DAY = 86_400

  def with_root(&)
    Dir.mktmpdir("dev-cleanup-", &)
  end

  def write(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  # Ages everything under path, then the path itself, so directory mtimes
  # aren't bumped back to now by writes inside them.
  def age(path, days:)
    time = NOW - (days * DAY)
    Dir.glob("#{path}/**/*", File::FNM_DOTMATCH).reverse_each do |entry|
      File.utime(time, time, entry) unless File.basename(entry) == "."
    end
    File.utime(time, time, path)
  end

  def make_derived_data(path)
    FileUtils.mkdir_p(File.join(path, "ModuleCache.noindex"))
    FileUtils.mkdir_p(File.join(path, "Build", "Intermediates.noindex"))
    File.write(File.join(path, "info.plist"), "<plist/>")
  end

  def target(path, days: 3, derived_data_days: nil)
    DevCleanup::Target.new(path:, days:, derived_data_days:)
  end

  def candidate_paths(candidates) = candidates.map(&:path).sort

  def test_children_untouched_for_longer_than_the_target_days_are_stale
    with_root do |root|
      stale = File.join(root, "OneSecondEveryday-old")
      fresh = File.join(root, "OneSecondEveryday-new")
      make_derived_data(stale)
      make_derived_data(fresh)
      age(stale, days: 5)
      age(fresh, days: 1)

      candidates = DevCleanup.stale_children(target(root), now: NOW)

      assert_equal [stale], candidate_paths(candidates)
    end
  end

  def test_a_recent_write_deep_inside_a_child_keeps_it
    with_root do |root|
      child = File.join(root, "one-850")
      make_derived_data(File.join(child, "wda-build"))
      age(child, days: 20)
      log = File.join(child, "wda-build", "Logs", "Build", "today.xcactivitylog")
      write(log, "Gnarly")
      File.utime(NOW, NOW, log)

      assert_empty DevCleanup.stale_children(target(root, days: 7), now: NOW)
    end
  end

  def test_loose_files_are_children_too
    with_root do |root|
      log = File.join(root, "mashing-flake-repro.log")
      write(log, "Closer")
      age(log, days: 9)

      assert_equal [log], candidate_paths(DevCleanup.stale_children(target(root), now: NOW))
    end
  end

  def test_symlinked_children_are_left_alone
    with_root do |root|
      elsewhere = File.join(root, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      dir = File.join(root, "scratch")
      FileUtils.mkdir_p(dir)
      File.symlink(elsewhere, File.join(dir, "link"))
      age(elsewhere, days: 30)
      File.lutime(NOW - (30 * DAY), NOW - (30 * DAY), File.join(dir, "link"))

      assert_empty DevCleanup.stale_children(target(dir), now: NOW)
    end
  end

  def test_stale_derived_data_inside_a_fresh_folder_is_found
    with_root do |root|
      folder = File.join(root, "OneSE-pr-6853-qa")
      stale_dd = File.join(folder, "dd-verify")
      fresh_dd = File.join(folder, "dd-verify-qa")
      notes = File.join(folder, "notes")
      make_derived_data(stale_dd)
      make_derived_data(fresh_dd)
      FileUtils.mkdir_p(notes)
      age(stale_dd, days: 4)
      age(notes, days: 4)

      candidates = DevCleanup.stale_derived_data(
        target(root, days: 7, derived_data_days: 3), now: NOW,
      )

      assert_equal [stale_dd], candidate_paths(candidates)
    end
  end

  def test_derived_data_inside_a_child_that_is_already_going_is_not_listed_twice
    with_root do |root|
      folder = File.join(root, "one-1149")
      make_derived_data(File.join(folder, "dd"))
      age(folder, days: 10)
      t = target(root, days: 7, derived_data_days: 3)

      candidates = DevCleanup.candidates_for(t, now: NOW)

      assert_equal [folder], candidate_paths(candidates)
    end
  end

  def test_in_use_matches_whole_path_components_only
    busy = [
      "xcodebuild test -derivedDataPath /scratch/one-850/wda-build -destination id=X",
      "/scratch/OneSE-pr-6853-qa",
    ]

    assert DevCleanup.in_use?("/scratch/one-850", busy)
    assert DevCleanup.in_use?("/scratch/one-850/wda-build", busy)
    assert DevCleanup.in_use?("/scratch/OneSE-pr-6853-qa", busy)
    refute DevCleanup.in_use?("/scratch/one-85", busy)
    refute DevCleanup.in_use?("/scratch/OneSE-pr-6853", busy)
  end

  def simulator(name:, state: "Shutdown", last_used_at: "2026-09-01T00:00:00Z", available: true)
    {
      "udid" => "UDID-#{name}", "name" => name, "state" => state, "lastUsedAt" => last_used_at,
      "isAvailable" => available, "dataPathSize" => 6_000_000_000,
    }
  end

  def test_only_old_shut_down_simulators_with_custom_names_are_stale
    devices = {
      "devices" => {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
          simulator(name: "ONE-556"),
          simulator(name: "OneSE-one-1113", last_used_at: "2026-10-20T00:00:00Z"),
          simulator(name: "ONE-892", state: "Booted"),
          simulator(name: "iPhone 17 Pro Max"),
          simulator(name: "Smashing Pumpkins"),
          simulator(name: "Never Booted", last_used_at: nil),
          simulator(name: "Unavailable", available: false),
        ],
      },
    }
    device_types = {"devicetypes" => [{"name" => "iPhone 17 Pro Max"}, {"name" => "iPhone Air"}]}

    stale = DevCleanup.stale_simulators(devices:, device_types:, days: 14, now: NOW)

    assert_equal ["ONE-556", "Smashing Pumpkins"], stale.map(&:name).sort
    assert_equal 6_000_000_000, stale.first.bytes
  end

  def test_config_adds_directories_and_overrides_defaults_by_path
    with_root do |root|
      path = File.join(root, "dev-cleanup.yml")
      File.write(path, <<~YAML)
        simulator_days: 30
        directories:
          - path: ~/.claude-scratchpad
            days: 7
            derived_data_days: 3
          - path: ~/Library/Developer/Xcode/DerivedData
            days: 10
      YAML

      config = DevCleanup::Config.load(path, home: "/Users/greg")

      assert_equal 30, config.simulator_days
      by_path = config.targets.to_h { [it.path, it] }
      assert_equal 7, by_path["/Users/greg/.claude-scratchpad"].days
      assert_equal 3, by_path["/Users/greg/.claude-scratchpad"].derived_data_days
      assert_equal 10, by_path["/Users/greg/Library/Developer/Xcode/DerivedData"].days
      assert_equal 3, by_path["/Users/greg/Library/Developer/FlowDeck/DerivedData"].days
      assert_equal 1, config.targets.count { it.path.end_with?("Xcode/DerivedData") }
    end
  end

  def test_a_missing_config_file_means_the_defaults
    config = DevCleanup::Config.load("/nonexistent/dev-cleanup.yml", home: "/Users/greg")

    assert_equal DevCleanup::DEFAULT_SIMULATOR_DAYS, config.simulator_days
    assert_includes config.targets.map(&:path), "/Users/greg/Library/Developer/Xcode/DerivedData"
  end

  def run_cleanup(root, delete:, busy: [])
    out = StringIO.new
    config = DevCleanup::Config.new(targets: [target(root)], simulator_days: 14)
    cleaner = DevCleanup::Cleaner.new(config:, delete:, busy:, simulators: false, out:, now: NOW)
    cleaner.run
    out.string
  end

  def test_a_dry_run_lists_without_deleting
    with_root do |root|
      stale = File.join(root, "stale")
      make_derived_data(stale)
      age(stale, days: 5)

      output = run_cleanup(root, delete: false)

      assert File.exist?(stale)
      assert_includes output, stale
      assert_includes output, "Would free"
    end
  end

  def test_deleting_removes_stale_paths_but_skips_ones_in_use
    with_root do |root|
      stale = File.join(root, "stale")
      busy = File.join(root, "busy")
      make_derived_data(stale)
      make_derived_data(busy)
      age(stale, days: 5)
      age(busy, days: 5)

      output = run_cleanup(root, delete: true, busy: ["xcodebuild -derivedDataPath #{busy}"])

      refute File.exist?(stale)
      assert File.exist?(busy)
      assert_includes output, "in use"
      assert_includes output, "Freed"
    end
  end
end
