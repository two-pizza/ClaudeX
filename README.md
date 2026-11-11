<h1 align="center">ClaudeX</h1>

<p align="center">
Claude &amp; Codex usage limits in your macOS menu bar.<br>
Know how much of your session and weekly window is left - without opening <code>/usage</code>.
</p>

<p align="center">
<img src="docs/panel.png" width="360" alt="ClaudeX panel">
</p>

## What it shows

Exactly what Claude Code's `/usage` screen shows - live in the menu bar:

- **Claude** - the 5-hour session window when your plan has one, weekly "All models", per-model weekly windows, reset times
- **Codex** (optional) - your ChatGPT plan's session and weekly windows

Only the windows are shown while everything works. The next scheduled refresh is in the
tooltip over the ring.

The ring in the menu bar reflects the hottest window: blue below 75%, orange from 75%, red from 90%.

When a provider cannot be refreshed, its last numbers stay on screen with an orange
**Stale · last update N min ago** line and the reason, and the widget marks it `stale`.
The other provider is unaffected, and an "Updated" footer then says when the newest
numbers arrived.
All refresh sources respect a separate schedule for each provider. Claude is polled
at most once every five minutes (or the selected interval, if longer); Codex follows
the selected interval. The interval submenu shows both effective values.
HTTP 429 pauses only the affected provider: a valid `Retry-After` takes precedence,
otherwise retries wait 5, 10, 20, then 30 minutes until a successful fetch.
Pauses and request times survive restarts. Manual refresh explains any wait in the
panel; a request already in progress cannot overlap another for the same provider.
On restart, the app restores the last widget snapshot with its original success
times and marks it stale until refreshed. A safety horizon caps implausible server
or stored pauses at 24 hours; future request-start times are corrected to the current
time after a backward clock change. Normal server pauses longer than 30 minutes
are still respected.

## Install

Requires a Mac with Apple silicon and Claude Code you are signed in to.
The menu bar app runs on macOS 13 or later; the build with the desktop widget needs macOS 14.

### Download

1. Download `ClaudeX-<version>-menubar.zip` from the [latest release](https://github.com/two-pizza/ClaudeX/releases/latest).
2. Unzip it and move `ClaudeX.app` to Applications.
3. Open the app. macOS blocks it the first time, because the build is not notarized by Apple.
4. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

The download is the menu bar app only; the desktop widget needs Xcode (see below).

### Build from source

```bash
git clone https://github.com/two-pizza/ClaudeX.git
cd ClaudeX
./build.sh --install
```

No Xcode, no dependencies - a single `swiftc` invocation from Command Line Tools.
The app lands in `~/Applications` and starts immediately.
This builds the menu bar app; the desktop widget needs Xcode (see below).

### First launch

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

## Desktop widget

A WidgetKit widget for the desktop and Notification Center is in the tree
(`Sources/Widget/`). It needs Xcode and an Apple Developer team, because the
data crosses an App Group:

```bash
# 1. put your Apple Developer team id in Team.xcconfig (one line, comments explain where to find it)
# 2. generate and build
xcodegen generate
xcodebuild -project ClaudeX.xcodeproj -scheme ClaudeX -configuration Release build
```

The App Group is derived from that team id, so app and widget always agree and
no source file needs editing. To verify the handoff actually works:

```bash
ClaudeX.app/Contents/MacOS/ClaudeX --diagnose
# App Group: <TEAM>.group.me.andrey.ClaudeX
#   container: available - the widget will receive updates
```

Check that line. A wrong team id still produces a valid-looking signed build -
one whose widget silently never receives anything.

The widget never fetches anything. A widget extension is sandboxed and cannot
reach the Keychain, so the app writes each fresh snapshot into the shared
container and calls `WidgetCenter.reloadAllTimelines()`; the widget only reads.
Only rendered numbers cross that boundary - never tokens.

The app itself is deliberately **not** sandboxed: the sandbox would cut off the
Keychain item it reads. The widget extension is sandboxed, as macOS requires.

## Menu

| Item | |
|---|---|
| **Refresh now** (⌘R) | refresh eligible providers; a rate-limit pause is shown in the panel |
| **Update Available: X…** | appears only when a newer release is out |
| **Settings ▸ Refresh every** | 1 / 2 / 5 / 15 minutes (default 2); Claude minimum 5 minutes |
| **Settings ▸ Compact** | ring only, no percentages |
| **Settings ▸ Show Codex usage** | hide/show the Codex section |
| **Settings ▸ Launch at login** | via `SMAppService` |
| **Settings ▸ Check for Updates…** | asks GitHub for the latest release and opens it in the browser; also checked quietly once a day |
| **Settings ▸ Open claude.ai usage settings** | the usage page on claude.ai |

## Test without network or credentials

```bash
swift test
./build.sh  # build only; does not install or launch the app
```

The tests use isolated UserDefaults suites, a controllable clock, fake providers,
and URLProtocol responses. They never read CLI credentials or call usage endpoints.

## Troubleshooting

```bash
# refresh eligible providers; print results or waiting status (tokens never printed)
~/Applications/ClaudeX.app/Contents/MacOS/ClaudeX --diagnose

# runtime log
tail -f ~/Library/Logs/ClaudeX.log
```

`--diagnose` respects the same saved pause and minimum interval as the app.
It may print only a waiting status without making a request; it does not bypass
rate limiting.

| Symptom | Cause / fix |
|---|---|
| `—` in the menu bar | first fetch failed; it retries automatically |
| "not logged in" | run `claude` (or `codex`) once and authenticate |
| "Token rejected" | same - the CLI refreshes its token on next run |
| "Rate limited" | the usage endpoint throttled us; the panel shows when another attempt is allowed |

## Code layout

| File | Responsibility |
|---|---|
| `Sources/Shared/Models.swift` | shared data model for both providers |
| `Sources/App/Keychain.swift` | Claude Code token from the Keychain |
| `Sources/App/Providers.swift` | Claude + Codex fetch and response parsing |
| `Sources/App/HTTPClient.swift` | transport retries and Retry-After parsing |
| `Sources/App/RefreshCoordinator.swift` | per-provider scheduling and persisted backoff |
| `Sources/App/UsagePanelContent.swift` | testable panel text and freshness |
| `Sources/App/UsageMenuView.swift` | the panel with limit bars |
| `Sources/App/StatusController.swift` | status item, ring icon, timer, settings |
| `Sources/App/Log.swift` | log file in `~/Library/Logs/` |
| `Sources/Shared/SharedStore.swift` | snapshot handoff to the widget |
| `Sources/Widget/` | WidgetKit extension (small / medium / large) |

See [ROADMAP.md](ROADMAP.md) for what's next (desktop widget, iOS, App Store).

## License

[MIT](LICENSE)
