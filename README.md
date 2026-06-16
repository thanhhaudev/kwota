# Kwota

Token usage tracker for AI coding assistants. Lives in the menu bar; auto-keeps your Mac awake while agents are working, and tracks caches on your machine.

Hobby project, built for fun. macOS 14.0+ to run, Xcode 26.4+ to build.

![Kwota preview](assets/preview.gif)

## Providers

| Provider    | Tracked                                              | Source                                                                          |
| ----------- | ---------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | 5-hour session, weekly limit, per-model breakdown    | `api.anthropic.com/api/oauth/usage` (OAuth via Claude CLI auth) + `~/.claude/projects/**/*.jsonl` |
| Codex       | 5-hour + weekly buckets                              | `wham/usage`                                                                    |
| Antigravity | Credit pools + per-model quotas                      | local Connect-RPC `GetUserStatus`                                               |

## Build

```bash
make build                       # debug
make run                         # build + launch
make release-app                 # release build → build/Release/Kwota.app
make test                        # unit tests (~90s, parallel)
make test-only SUITE=<Name>      # one suite, no rebuild
make test-all                    # include UI tests (serial)
make help                        # all targets
```

DerivedData is shared at `~/Library/Developer/Xcode/DerivedData/Kwota-shared`. The UI test target is excluded from `make test` by default.

## Install

The app runs without signing setup. To enable **system-cache cleaning** (needs a root helper):

1. Sign into your Apple ID in Xcode → Settings → Accounts → `+` (a free account
   works — Xcode creates a "Personal Team"; no paid Apple Developer Program
   needed). Then run the script — it finds your Team ID and writes
   `Local.xcconfig` for you:

   ```bash
   bash scripts/setup-signing.sh        # detects your Team ID, writes Local.xcconfig
   ```

   It reads the Team ID straight from your signing certificate and asks which to
   use if you have several. Prefer to do it by hand? Open `Kwota/Kwota.xcodeproj`
   → **Kwota** target → **Signing & Capabilities** → pick your team, read the ID
   with `grep -m1 DEVELOPMENT_TEAM Kwota/Kwota.xcodeproj/project.pbxproj`, set
   `DEVELOPMENT_TEAM = <that ID>` in `Local.xcconfig`, then revert the project
   file with `git checkout -- Kwota/Kwota.xcodeproj`.
2. `make release-app`, drag `build/Release/Kwota.app` to `/Applications`.
3. Settings → Cache → Privileged helper → **Install helper**, then approve it in System Settings → General → Login Items.

If **Install helper** errors after a previous attempt: `sudo sfltool resetbtm`.

## Keeping the signature fresh

A development signature has no secure timestamp, so once its certificate
expires (typically ~1 year out) macOS stops launching the installed app and
launchd stops loading the privileged helper. Rebuilding re-signs with a freshly
renewed certificate.

To automate this for the app you keep in `/Applications`:

```bash
bash scripts/install-signing-refresh.sh             # install the LaunchAgent
bash scripts/install-signing-refresh.sh uninstall   # remove it
```

It installs a per-user LaunchAgent that runs weekly (and at each login). Each
run checks `/Applications/Kwota.app`: if its signature no longer verifies, or
its certificate is within 30 days of expiring, it rebuilds Release (Xcode
renews the certificate automatically), swaps the bundle in place, and relaunches
it if it was running. It stays dormant until the app is actually in
`/Applications`, so dev builds from `make run` are never touched. Logs land in
`~/Library/Logs/kwota-signing-refresh.log`. You can also run a check on demand
with `bash scripts/refresh-signing.sh`.

## Tabs

**Usage** — per-provider quota view (see the Providers table above). Each provider gets a session chart with an `avg` reference line (typical % at the same point in past cycles) and a pace hint ("on pace", "above typical", "below typical"). A Free-plan overlay shows for Claude accounts with no paid subscription.

**Stats** — token-usage history for the active provider, in the Screen Time idiom. Pick a range (Today / last 7 days / last 30 days / all time); the chart stacks bars by model on a real time axis — per hour for Today, per day/week/month/year as the window grows — with a dashed daily-average line on the multi-day views. Below it, a per-model grid splits each model's total into `↓ in / ↑ out / ⚡ cache`. Tap a bar to read off that bucket. Providers without token data show an empty state.

**Awake** — toggle keep-awake (manual / auto / battery-aware). Below it: a multi-provider activity chart of recent agent replies. The chart shades each awake interval by mode — auto (green) or manual (blue). Battery (orange) shows up as the status dot in the card, menu-bar icon, and Settings row when auto is blocked by a low-battery threshold.

**Cache** — tracks caches across your machine: developer tooling (Xcode DerivedData, npm / bun / yarn / pnpm, pip, Homebrew, JetBrains, VS Code, Cursor), iOS Simulator / DeviceSupport, the macOS Icon services cache, generic `~/.cache`, and more. Each row shows a size breakdown and an AI evaluation. System-wide caches that need root also appear here once the privileged helper is installed.

## How polling works

One self-rescheduling timer:
- Popover open: ~60s
- Popover closed: ~10min
- ±20% jitter on every interval
- A 429 sets a per-provider back-off floor (from `Retry-After`); other providers keep polling

Manual refresh (chart button or "Refresh" shortcut) respects the same back-off and a short anti-spam throttle.

## How token data is collected

Kwota never invokes `claude`, `codex`, or `agy` to read usage — that would burn quota.

The Cache tab's "AI evaluation" is the one feature that does spawn a CLI — `claude -p`, `codex exec`, or `agy -p` for whichever provider is active (the providers gate 3rd-party API access, so their own CLI is the only reliable path). It uses your normal subscription quota; Kwota tells you when it happens.

## How stats are collected

Stats read the same on-disk logs the providers already write — no extra `claude` / `codex` / `agy` calls:

| Provider    | Source                                                         |
| ----------- | ------------------------------------------------------------- |
| Claude Code | `~/.claude/projects/**/*.jsonl`                               |
| Codex       | rollout `sessions/**/rollout-*.jsonl` + trace `logs_*.sqlite` |
| Antigravity | conversation SQLite (`gen_metadata` table)                   |

Kwota tails each log from a persisted cursor, so each turn is counted exactly once. First launch reads existing history as a one-time backfill — for Codex and Antigravity, per-turn token counts live only in these logs. Hourly buckets (the Today view) start from your next activity; already-read events can't be re-bucketed. The rollup is UTC-anchored so changing timezone doesn't reshuffle past days, and is kept until you clear it in Settings → Data & Storage.

## How the avg line is computed

Kwota stores raw `(timestamp, % used)` samples and segments them into completed cycles — 5-hour cycles for the session view, 7-day cycles for the weekly view.

A cycle ends when the next sample's value drops by ≥5 percentage points (smaller drops are server-side rounding noise; a real reset is ~95+). The trailing in-progress cycle is excluded so the line compares against finished history, not a partial sample.

For any elapsed time `t` in the current cycle, `avg(t)` is the mean of `value(t)` across past cycles — "what % were you typically at, this far in". The chart draws it as a reference line alongside the current cycle's series; the pace hint reads "on pace" / "above typical" / "below typical" by comparing the current point against `avg(t)`.

## How the session/week chart renders

Claude and Codex share the same chart. Two views:

- **Session** — bars per hour of the current 5-hour cycle. The latest bar is the focal bar; an extra ghost bar projects the next hour from up to the last 3 hour-to-hour deltas.
- **Week** — bars per day of the current 7-day cycle.

Each bar's color comes from its own value — green → yellow → red as it approaches the limit. The session's focal bar adds a slow "warm pulse" when the pace is heavy. The dashed green `avg` line (toggleable) sits over the bars. Before the first successful fetch, the chart shows "Waiting for first fetch…".

## Notes

- Sandbox-disabled. Holds IOKit power assertions to keep the Mac awake (no `caffeinate` child process), probes `claude --version` / `codex --version` / `agy --version`, and reads `~/.claude/`, `~/.codex/`, and `~/.gemini/antigravity*/` directly. Distribute as a Developer-ID-signed `.app`, not via the Mac App Store.
- `claude` / `codex` / `agy` are resolved against an augmented PATH that includes `/opt/homebrew/bin` and `/usr/local/bin`.
- No remote backend — only reads provider files and APIs.
