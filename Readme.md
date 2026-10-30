# dev-cleanup

Frees the disk space that Xcode, FlowDeck and agent scratch folders pile up on
a Mac and never give back: DerivedData and SwiftPM `.build` folders nobody
has built into lately, old FlowDeck logs, Gradle and Homebrew caches,
outdated device support files, and simulators that were made for one task
and never booted again. When the disk still runs low, it removes the least
recently built DerivedData until there's room again. It's one Ruby file
with no gems, and it needs Ruby 3.4 or later.

```zsh
./dev-cleanup.rb             # dry run: list what would go and how big it is
./dev-cleanup.rb --delete    # actually delete it
./dev-cleanup.rb --install   # run --delete hourly with launchd
./dev-cleanup.rb --uninstall
```

Start with a dry run to see what it would delete.

## What goes

- **Xcode and FlowDeck DerivedData, and FlowDeck logs,** once untouched for 3
  days. Untouched means nothing in the folder, down to 4 levels deep, was
  modified in that time, so a recent build keeps its folder even when the
  top level looks old.
- **Gradle caches and wrapper distributions, and Homebrew downloads,** once
  untouched for 14 days.
- **Device support files** for all but the newest OS version of each device
  model, from `~/Library/Developer/Xcode/* DeviceSupport`. Xcode copies them
  again if an older device connects.
- **Simulators** that are shut down, haven't been used in 14 days and have a
  custom name. Simulators named after their device type ("iPhone 17 Pro")
  stay, as do any the `keep_simulators` list matches. Unavailable ones go too,
  via `simctl delete unavailable`.
- **Anything a running process is using is skipped.** That's anything a
  process mentions in its arguments or has as its working directory.

Folders that don't exist are skipped, so you don't need FlowDeck.

## When the disk runs low

After all that, if less than `min_free_gb` (150 GB) is free, it keeps going
through the DerivedData and `.build` folders it knows about, oldest build
first, until enough is free. Anything built in the last `evict_after_hours`
(6) stays, as does anything in use, however low the disk is. Shared caches
such as `CompilationCache.noindex` are never touched. Set `min_free_gb: 0`
to turn this off.

## Configuration

Add folders, or change the defaults, in `~/.config/dev-cleanup.yml`:

```yaml
simulator_days: 14
min_free_gb: 150
evict_after_hours: 6
keep_simulators:
  - ci-golden-*          # globs allowed
  - 0EAE92DA-184D-4B49-9D4F-812E0EF6FB16
directories:
  - path: ~/.claude-scratchpad
    days: 7                # remove top-level entries untouched this long
    derived_data_days: 3   # and build folders found inside, sooner
  - path: ~/Developer
    derived_data_days: 3   # build folders only, nothing else goes
  - path: ~/Library/Developer/Xcode/DerivedData
    days: 5
```

Build folders are DerivedData and SwiftPM `.build` folders (ones next to a
`Package.swift`), found up to 3 levels down. An entry needs `days`,
`derived_data_days` or both. An entry with the same path as a default
replaces it. `keep_simulators` entries are matched against both the name and
the UDID, ignoring case.

## The launchd agent

`--install` copies the script to `~/Library/Application Support/dev-cleanup`,
so the agent doesn't depend on your checkout. The agent runs it with the Ruby
that ran the install. Re-run `--install` after pulling changes, or after
removing that Ruby. It runs on the hour, and if the Mac is asleep then, the run
happens when it wakes. Each run appends what it removed to
`~/Library/Logs/dev-cleanup.log`.

## Tests

```zsh
ruby -w test/dev_cleanup_test.rb
```
