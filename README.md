# ai-mac-swift-homobar

A macOS menu bar item that shows what jobs are running: Cursor cloud agents and open PRs on `ZeroNerodaHero/slop-stream-architecture`. It's a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin that refreshes every 30 seconds (the `30s` in the filename sets that).

## What it shows
- Menu bar: `⚙ N · PR M` while agents run, `✓` when idle (red if a recent run failed), `⚙ ?` when no API key, `⚙ !` if the API errors.
- Dropdown: running agents with age and links, agents that ended in the last 6h, open PRs, Refresh now.
- One macOS notification when the running count drops to 0.

## Setup
1. `brew install --cask swiftbar`, then set SwiftBar's plugin folder to this repo (or copy `jobs.30s.py` into your plugin folder).
2. Create a Cursor API key at https://cursor.com/dashboard (API Keys).
3. Store it in Keychain (paste at the prompt, it stays out of shell history):
   `security add-generic-password -a $USER -s cursor-api-key -w`
   Or put it in `~/.config/job-menubar/key` with `chmod 600`.
4. Allow SwiftBar keychain access if asked; turn on "Launch at login" in SwiftBar settings.

Requires `gh` logged in for the PR section. Never commit your key.
