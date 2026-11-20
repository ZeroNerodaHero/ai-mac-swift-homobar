# Job menu bar

Shows Billy's Cursor cloud agents (running, failed, done) and open PRs on
`ZeroNerodaHero/slop-stream-architecture` in the macOS menu bar. Two options:

| | SwiftBar plugin (`jobs.30s.py`) | Native app (`Jobbar.app`) |
|---|---|---|
| UI | Plain dropdown menu | Scrollable popover, filters (All / Running / Failed / Done / PRs), search |
| Needs | SwiftBar + Homebrew Python | Nothing at runtime (build needs Xcode / Swift 5.9+) |
| Refresh | Every 30s | Every 30s, plus refresh button (⌘R) |

Both share the "failures seen" marker in `~/.config/job-menubar/state.json`, so
marking failures seen in one clears the red indicator in the other.

## API key (both)

The Cursor API key (cursor.com/dashboard → API Keys) is read from the macOS Keychain:

```sh
security add-generic-password -a "$USER" -s cursor-api-key -w   # prompts for the key
```

Fallback: `~/.config/job-menubar/key` (chmod 600). The key is never printed or logged,
and must never be committed.

## Menu bar title

- `⚙ N · PR M`: N agents running, M open PRs
- `✓ · PR M`: nothing running
- red `✗ K` appended: K failed runs in the last 24h that you haven't marked seen
- `⚙ ?`: no API key; `⚙ !`: Cursor API error

## Option 1: SwiftBar plugin

`jobs.30s.py` lists v1 agents, keeps ACTIVE ones plus ones updated in the last 24h,
and reads each one's latest run status. Sections: Running, Failed in last 24h
(e.g. "failed after 2s"), Ended in last 6h, Open PRs. If a run lookup fails the
agent shows ⚠️ UNKNOWN instead of being assumed finished. "Mark failures seen" runs
`jobs.30s.py --mark-seen`.

Install: SwiftBar's plugin folder (`~/Documents/axiom/job-menubar`) holds a symlink to
this repo's script, so pulling the repo updates the plugin:

```sh
ln -sf "$PWD/jobs.30s.py" ~/Documents/axiom/job-menubar/jobs.30s.py
open -g swiftbar://refreshallplugins
```

(Don't point SwiftBar's plugin folder at the repo itself: SwiftBar would try to run
`build.sh` as a plugin.)

Testing without the API: `JOBBAR_FIXTURE=/path/to/fixtures ./jobs.30s.py`.

## Option 2: native app (Jobbar)

SwiftUI `MenuBarExtra` app in `MenuBarApp/` (macOS 13+). Click a job to open it on
cursor.com; the PR button opens its pull request. It sends notifications when all
running jobs finish and when a new failure appears.

```sh
./build.sh            # builds build/Jobbar.app (ad-hoc signed, menu bar only, no Dock icon)
open build/Jobbar.app
./build.sh --install  # also copies it to ~/Applications
```

To start it at login: System Settings → General → Login Items → add Jobbar.app.
Quit from the popover's Quit button (⌘Q).

If you run both the plugin and the app, you get two menu bar items and duplicate
notifications. Turn off whichever one you don't want (SwiftBar: disable the plugin;
Jobbar: Quit and remove it from Login Items).
