<h1 align="center">UsageBar</h1>

<p align="center">
Claude &amp; Codex usage limits in your macOS menu bar.<br>
Know how much of your session and weekly window is left - without opening <code>/usage</code>.
</p>

<p align="center">
<img src="docs/panel.png" width="360" alt="UsageBar panel">
</p>

## What it shows

Exactly what Claude Code's `/usage` screen shows - live in the menu bar:

- **Claude** - current 5-hour session, weekly "All models", per-model weekly windows, reset times
- **Codex** (optional) - your ChatGPT plan's session and weekly windows

The ring in the menu bar reflects the hottest window: blue below 75%, orange from 75%, red from 90%.

## Install

```bash
git clone https://github.com/two-pizza/ClaudeUsageBar.git
cd ClaudeUsageBar
./build.sh --install
```

That's it. No Xcode project, no dependencies - a single `swiftc` invocation from
Command Line Tools. The app lands in `~/Applications` and starts immediately.
Or grab a prebuilt app from [Releases](https://github.com/two-pizza/ClaudeUsageBar/releases).

On first launch macOS may ask for Keychain access - click **Always Allow**.
The permission is granted to `/usr/bin/security`, so rebuilding the app never re-prompts.

## How it works

**Claude.** `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token
Claude Code already keeps in your Keychain (`Claude Code-credentials`). The response
carries the same `limits[]` array Claude Code renders in `/usage` - so new windows
("Fable", per-model buckets) appear automatically, with no code changes here.

**Codex.** `GET https://chatgpt.com/backend-api/wham/usage` with the token Codex CLI
keeps in `~/.codex/auth.json`. Shown automatically when Codex is installed;
toggle it off in the menu if you don't want it.

**Tokens are read-only - never refreshed.** Refreshing rotates the refresh token
and would steal the CLI's own authorization. If a token expires, the panel says so;
running `claude` or `codex` once fixes it.

## Menu

| Item | |
|---|---|
| **Refresh now** (⌘R) | fetch immediately; also refreshes on menu open and on wake from sleep |
| **Refresh every** | 1 / 2 / 5 / 15 minutes (default 2) |
| **Compact** | ring only, no percentages |
| **Show Codex usage** | hide/show the Codex section |
| **Launch at login** | via `SMAppService` |

## Troubleshooting

```bash
# one fetch per provider, printed to the console (tokens never printed)
~/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --diagnose

# runtime log
tail -f ~/Library/Logs/ClaudeUsageBar.log
```

| Symptom | Cause / fix |
|---|---|
| `—` in the menu bar | first fetch failed; it retries automatically |
| "not logged in" | run `claude` (or `codex`) once and authenticate |
| "Token rejected" | same - the CLI refreshes its token on next run |
| "Rate limited" | the usage endpoint throttled us; next tick recovers |

## Code layout

| File | Responsibility |
|---|---|
| `Sources/Models.swift` | shared data model for both providers |
| `Sources/Keychain.swift` | Claude Code token from the Keychain |
| `Sources/Providers.swift` | Claude + Codex fetch and response parsing |
| `Sources/UsageMenuView.swift` | the panel with limit bars |
| `Sources/StatusController.swift` | status item, ring icon, timer, settings |
| `Sources/Log.swift` | log file in `~/Library/Logs/` |

See [ROADMAP.md](ROADMAP.md) for what's next (desktop widget, iOS, App Store).

## License

[MIT](LICENSE)
