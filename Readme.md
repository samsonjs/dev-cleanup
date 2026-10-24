# dev-cleanup

Frees the disk space that Xcode, FlowDeck and agent scratch folders pile up on
a Mac and never give back: DerivedData nobody has built into lately, old
FlowDeck logs, and simulators that were made for one task and never booted
again. It's one Ruby file with no gems, and it needs Ruby 3.4 or later.

```zsh
./dev-cleanup.rb             # dry run: list what would go and how big it is
./dev-cleanup.rb --delete    # actually delete it
./dev-cleanup.rb --install   # run --delete daily at 04:00 with launchd
./dev-cleanup.rb --uninstall
```

Start with a dry run to see what it would delete.

## What goes

- **Xcode and FlowDeck DerivedData, and FlowDeck logs,** once untouched for 3
  days. Untouched means nothing in the folder, down to 4 levels deep, was
  modified in that time, so a recent build keeps its folder even when the
  top level looks old.
- **Simulators** that are shut down, haven't been used in 14 days and have a
  custom name. Simulators named after their device type ("iPhone 17 Pro")
  stay. Unavailable ones go too, via `simctl delete unavailable`.
- **Anything a running process is using is skipped.** That's anything a
  process mentions in its arguments or has as its working directory.

Folders that don't exist are skipped, so you don't need FlowDeck.

## Configuration

Add folders, or change the defaults, in `~/.config/dev-cleanup.yml`:

```yaml
simulator_days: 14
directories:
  - path: ~/.claude-scratchpad
    days: 7                # remove top-level entries untouched this long
    derived_data_days: 3   # and DerivedData folders found inside, sooner
  - path: ~/Library/Developer/Xcode/DerivedData
    days: 5
```

An entry with the same path as a default replaces it.

## The launchd agent

`--install` copies the script to `~/Library/Application Support/dev-cleanup`,
so the agent doesn't depend on your checkout. The agent runs it with the Ruby
that ran the install. Re-run `--install` after pulling changes, or after
removing that Ruby. If the Mac is asleep at 04:00, the run happens when it
wakes. Each run appends what it removed to `~/Library/Logs/dev-cleanup.log`.

## Tests

```zsh
ruby -w test/dev_cleanup_test.rb
```
