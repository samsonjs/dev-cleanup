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

  def test_swiftpm_build_folders_count_but_nothing_else_goes_without_days
    with_root do |root|
      package = File.join(root, "OneSE", "OSERewind")
      build = File.join(package, ".build")
      write(File.join(package, "Package.swift"), "// swift-tools-version: 6.2")
      write(File.join(build, "index-build", "build.db"), "x")
      write(File.join(root, "dotfiles", ".build", "not-swiftpm"), "x")
      age(root, days: 30)

      t = target(root, days: nil, derived_data_days: 3)

      candidates = DevCleanup.candidates_for(t, now: NOW)

      assert_equal [build], candidate_paths(candidates)
    end
  end

  def test_config_allows_a_directory_searched_only_for_build_folders
    with_root do |root|
      path = File.join(root, "dev-cleanup.yml")
      File.write(path, <<~YAML)
        directories:
          - path: ~/Developer
            derived_data_days: 3
      YAML

      config = DevCleanup::Config.load(path, home: "/Users/greg")
      developer = config.targets.find { it.path == "/Users/greg/Developer" }

      assert_nil developer.days
      assert_equal 3, developer.derived_data_days
    end
  end

  def test_config_rejects_a_directory_with_neither_kind_of_days
    with_root do |root|
      path = File.join(root, "dev-cleanup.yml")
      File.write(path, "directories:\n  - path: ~/Developer\n")

      assert_raises(ArgumentError) { DevCleanup::Config.load(path, home: "/Users/greg") }
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

  def test_simulators_on_the_keep_list_are_never_stale
    devices = {
      "devices" => {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [
          simulator(name: "ci-golden-iPhone-17-Pro-27.0-24A434"),
          simulator(name: "ci-golden-iPhone-16-Pro-18.6-22G86"),
          simulator(name: "Bad Religion"),
          simulator(name: "NOFX"),
        ],
      },
    }
    device_types = {"devicetypes" => [{"name" => "iPhone 17 Pro"}]}

    stale = DevCleanup.stale_simulators(
      devices:, device_types:, days: 14, now: NOW, keep: ["ci-golden-*", "udid-nofx"],
    )

    assert_equal ["Bad Religion"], stale.map(&:name)
  end

  def test_the_keep_list_is_empty_by_default
    devices = {
      "devices" => {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0" => [simulator(name: "ci-golden-leftover")],
      },
    }

    stale = DevCleanup.stale_simulators(
      devices:, device_types: {"devicetypes" => []}, days: 14, now: NOW,
    )

    assert_equal ["ci-golden-leftover"], stale.map(&:name)
  end

  def test_config_reads_the_keep_list
    with_root do |root|
      path = File.join(root, "dev-cleanup.yml")
      File.write(path, <<~YAML)
        keep_simulators:
          - ci-golden-*
          - 0EAE92DA-184D-4B49-9D4F-812E0EF6FB16
      YAML

      config = DevCleanup::Config.load(path, home: "/Users/greg")

      assert_equal ["ci-golden-*", "0EAE92DA-184D-4B49-9D4F-812E0EF6FB16"], config.keep_simulators
    end
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
    assert_empty config.keep_simulators
    assert_includes config.targets.map(&:path), "/Users/greg/Library/Developer/Xcode/DerivedData"
  end

  def test_config_reads_the_free_space_settings
    with_root do |root|
      path = File.join(root, "dev-cleanup.yml")
      File.write(path, <<~YAML)
        min_free_gb: 0
        evict_after_hours: 12
      YAML

      config = DevCleanup::Config.load(path, home: "/Users/greg")

      assert_equal 0, config.min_free_gb
      assert_equal 12, config.evict_after_hours
    end
  end

  def test_the_free_space_defaults
    config = DevCleanup::Config.load("/nonexistent/dev-cleanup.yml", home: "/Users/greg")

    assert_equal DevCleanup::DEFAULT_MIN_FREE_GB, config.min_free_gb
    assert_equal DevCleanup::DEFAULT_EVICT_AFTER_HOURS, config.evict_after_hours
  end

  def test_the_defaults_cover_gradle_and_homebrew_caches
    config = DevCleanup::Config.load("/nonexistent/dev-cleanup.yml", home: "/Users/greg")
    paths = config.targets.map(&:path)

    assert_includes paths, "/Users/greg/.gradle/caches"
    assert_includes paths, "/Users/greg/.gradle/wrapper/dists"
    assert_includes paths, "/Users/greg/Library/Caches/Homebrew/downloads"
  end

  def test_only_the_newest_device_support_per_device_model_is_kept
    with_root do |root|
      names = [
        "iPhone14,4 26.7.1 (23H30)", "iPhone14,4 27.0.1 (24A446)", "iPhone14,4 26.10 (23J5)",
        "iPhone18,1 27.0.1 (24A446)", "Watch7,1 11.2 (22S5)", "Watch7,1 12.0 (23R3)", "notes",
      ]
      names.each { FileUtils.mkdir_p(File.join(root, it)) }

      stale = DevCleanup.stale_device_support(root)

      assert_equal(
        ["Watch7,1 11.2 (22S5)", "iPhone14,4 26.10 (23J5)", "iPhone14,4 26.7.1 (23H30)"],
        stale.map { File.basename(it) }.sort,
      )
    end
  end

  def run_cleanup(root, delete:, busy: [], free_bytes: 1024**4, device_support_roots: [])
    out = StringIO.new
    config = DevCleanup::Config.new(
      targets: [target(root)], simulator_days: 14, min_free_gb: 1, evict_after_hours: 6,
    )
    cleaner = DevCleanup::Cleaner.new(
      config:, delete:, busy:, free_bytes:, device_support_roots:, simulators: false, out:,
      now: NOW,
    )
    cleaner.run
    out.string
  end

  MB = 1024**2
  GB = 1024**3

  def make_build(path, days:)
    make_derived_data(path)
    write(File.join(path, "Build", "Intermediates.noindex", "blob"), "x" * MB)
    age(path, days:)
  end

  def test_when_free_space_is_short_the_least_recently_built_derived_data_goes_first
    with_root do |root|
      fugazi = File.join(root, "OneSE-fugazi")
      slint = File.join(root, "OneSE-slint")
      pinback = File.join(root, "OneSE-pinback")
      make_build(fugazi, days: 2)
      make_build(slint, days: 1.5)
      make_build(pinback, days: 1)

      output = run_cleanup(root, delete: true, free_bytes: GB - (MB * 3 / 2))

      refute File.exist?(fugazi)
      refute File.exist?(slint)
      assert File.exist?(pinback)
      assert_includes output, "short of 1 GB free"
    end
  end

  def test_nothing_is_evicted_while_free_space_is_above_the_target
    with_root do |root|
      build = File.join(root, "OneSE-fugazi")
      make_build(build, days: 2)

      output = run_cleanup(root, delete: true, free_bytes: 2 * GB)

      assert File.exist?(build)
      refute_includes output, "short of"
    end
  end

  def test_recent_builds_builds_in_use_and_shared_caches_are_never_evicted
    with_root do |root|
      recent = File.join(root, "OneSE-recent")
      busy = File.join(root, "OneSE-busy")
      cache = File.join(root, "CompilationCache.noindex")
      make_build(busy, days: 2)
      write(File.join(cache, "blob"), "x" * MB)
      age(cache, days: 2)
      make_build(recent, days: 0.1)

      run_cleanup(
        root, delete: true, free_bytes: 0, busy: ["xcodebuild -derivedDataPath #{busy}"],
      )

      assert File.exist?(recent)
      assert File.exist?(busy)
      assert File.exist?(cache)
    end
  end

  def test_derived_data_nested_in_a_scratch_folder_can_be_evicted
    with_root do |root|
      folder = File.join(root, "OneSE-one-982")
      build = File.join(folder, "dd")
      notes = File.join(folder, "notes.md")
      make_build(build, days: 2)
      write(notes, "Big Lebowski")

      run_cleanup(root, delete: true, free_bytes: 0)

      refute File.exist?(build)
      assert File.exist?(notes)
    end
  end

  def test_a_dry_run_counts_what_aging_out_would_free_before_evicting
    with_root do |root|
      stale = File.join(root, "OneSE-stale")
      young = File.join(root, "OneSE-young")
      make_build(stale, days: 5)
      make_build(young, days: 2)

      output = run_cleanup(root, delete: false, free_bytes: GB - (MB / 2))

      assert File.exist?(stale)
      assert File.exist?(young)
      assert_includes output, stale
      refute_includes output, young
    end
  end

  def test_a_dry_run_lists_evictions_without_deleting
    with_root do |root|
      build = File.join(root, "OneSE-fugazi")
      make_build(build, days: 2)

      output = run_cleanup(root, delete: false, free_bytes: 0)

      assert File.exist?(build)
      assert_includes output, build
      assert_includes output, "Would free"
    end
  end

  def test_device_support_for_older_versions_is_removed
    with_root do |root|
      support = File.join(root, "iOS DeviceSupport")
      old = File.join(support, "iPhone14,4 26.7.1 (23H30)")
      current = File.join(support, "iPhone14,4 27.0.1 (24A446)")
      write(File.join(old, "Symbols", "dyld"), "x")
      write(File.join(current, "Symbols", "dyld"), "x")

      output = run_cleanup(root, delete: true, device_support_roots: [support])

      refute File.exist?(old)
      assert File.exist?(current)
      assert_includes output, old
    end
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

  def test_the_launchd_job_runs_every_hour_on_the_hour
    job = DevCleanup.launchd_job(script: "/tmp/dev-cleanup.rb")

    assert_equal({"Minute" => 0}, job["StartCalendarInterval"])
    assert_equal [RbConfig.ruby, "/tmp/dev-cleanup.rb", "--delete"], job["ProgramArguments"]
  end
end
