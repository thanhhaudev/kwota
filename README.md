# Kwota

macOS menu bar app for tracking Claude Code, Codex, and Antigravity token usage. Reads each provider's own files and APIs — never invokes the CLIs in a way that consumes quota. Also toggles `caffeinate` and previews the on-disk Claude cache.

Requires macOS 14.0+ and Xcode 16+ to build.

## Status

Personal project. One person uses it; the public repo is a single `init project` commit so the source is readable end-to-end.

## What it shows

Three tabs in the menu bar popover.

### Usage

For the active profile, the Usage tab renders the provider's own quota model:

- **Claude** — current 5-hour session window (used / limit, time-to-reset), weekly limit, per-model breakdown, extra-usage line, and a Free-plan overlay when the account has no paid subscription.
- **Codex** — five-hour and weekly buckets read from `wham/usage`.
- **Antigravity** — Claude+GPT shared pool, Gemini High, Gemini Low, surfaced from a local Connect-RPC `GetUserStatus`.

Each provider's view also renders a **session-usage chart** with an `avg` reference line:

- The `avg` line is the typical % used at the same elapsed time in past *completed* cycles. For Claude/Codex sessions this is 5h cycles; for the weekly view it's 7-day cycles. The math lives in `SessionAvgCalculator` / `WeekAvgCalculator`.
- A cycle is considered completed when the next sample's value drops by ≥5.0 vs the previous (a reset). The trailing in-progress cycle is excluded so you compare against past finished cycles, not a partial sample.

The bottom of the usage card surfaces a **pace hint** ("on track", "above typical at this point", etc.) by comparing the current cycle's elapsed-vs-used point against the avg line.

### Awake

Toggle macOS `caffeinate` (manual, auto, or battery-aware mode). Holds an `IOPMAssertionCreateWithName` while active.

Below the toggle is an **activity chart** showing recent agent activity per provider:

- Data source: `ActivityHistorian` keeps a ring buffer of recent agent-reply timestamps. Backfilled at launch from disk (`~/.claude/projects/**/*.jsonl` for Claude; equivalent transcript files for Codex/Antigravity), then streamed from `UsageMonitor.tick()` as the JSONL files grow.
- Multi-provider: each active provider gets its own colored series (Claude coral, Codex teal, Antigravity violet). With 2+ active, normalization is global so all series share the same Y axis.
- Keep-awake reasons are stacked separately: auto (green), manual (blue), battery (orange). Footer shows per-provider event counts.

### Cache

Previews the on-disk Claude cache (`~/.claude/projects/`) with size breakdown and an AI-evaluated safety verdict per row. Also shows system-wide icon caches when the privileged helper is installed (see below).

## How it stays fresh

`UsageRefreshCoordinator` owns one self-rescheduling Timer:

- **Popover open** — base interval 60 seconds.
- **Popover closed** — base interval 10 minutes.
- Each scheduled delay is jittered by ±20% to avoid a fixed-period fingerprint.
- A 429 from any provider sets a **per-provider** back-off floor (`Retry-After` header). Other providers keep polling — a Claude 429 does not block Antigravity, which talks to a local loopback with no rate limit.
- The Timer skips its tick while ANY provider's floor is still in the future; the next tick is scheduled after the max floor.

`MenuBarViewModel.refreshUsageNow()` is the manual trigger (used by the chart's refresh button and the "Refresh" keyboard shortcut). It still respects the per-provider back-off floor and a short anti-spam throttle.

## How it tracks tokens passively

Kwota never invokes `claude`/`codex` to read usage — that would consume the user's own quota.

- **Claude:** Token totals come from `claude.ai/api/usage` via the user's cached OAuth token (refreshed via `CLITokenRefresher`, with a one-time 401 retry via `forceRefresh`). Daily counters and agent-event timestamps come from tailing `~/.claude/projects/**/*.jsonl` directly (FSEvents-backed).
- **Codex:** Same shape against `wham/usage`. Token cached/refreshed via `CodexTokenRefresher`.
- **Antigravity:** Talks to the locally-running language_server's Connect-RPC endpoint (`GetUserStatus`); activity tracked by file-watching the transcript directory.

The Cache tab's "AI evaluation" is the one place Kwota deliberately spawns `claude -p` — Anthropic blocks third-party OAuth bearer access to `/v1/messages`, so the evaluation is unavoidable if you want it. Each evaluation consumes the user's normal subscription quota and is surfaced as such.

## Build & run

```bash
make build          # debug build
make run            # build + launch
make test           # full unit suite (~90s, parallel)
make release-app    # release build to build/Release/Kwota.app
make help           # full target list
```

The Makefile pins a shared DerivedData path so worktrees + subagent invocations share the incremental cache. The first build in any fresh clone is incremental, not cold.

## Signing & install

The app runs ad-hoc except for **system-cache cleaning**, which uses a root LaunchDaemon (`KwotaPrivilegedHelper`) installed via `SMAppService`. To install:

1. Copy `Local.xcconfig.example` to `Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM` to your own Apple team ID. `make build` does this copy automatically on first run if the file is missing — leave it empty for ad-hoc.
2. `make release-app` → `build/Release/Kwota.app`. Drag to `/Applications`.
3. In the app: Settings → Cache → Privileged helper → Install. Approve in System Settings → General → Login Items & Extensions.

Any Apple ID added to Xcode (Settings → Accounts) is enough — the helper's XPC requirement binds to the signing team at runtime, so any team works. A paid Apple Developer Program is only required to distribute the app to other Macs.

If you previously experimented with the helper and `Install` returns errors, clear the stale registration once: `sudo sfltool resetbtm`.

## Tests

```bash
make test                                    # all unit tests
make test-only SUITE=<SuiteName>             # single suite, no rebuild
make test-all                                # include the UI test target
```

The UI test target is auto-generated and excluded from the default `make test` to keep the run hermetic.

## Notes

- The app is sandbox-disabled. It launches `/usr/bin/caffeinate`, probes `/usr/bin/env claude --version`, holds IOKit power assertions, and reads `~/.claude/` directly. Distribute as a Developer-ID-signed `.app`, not via the Mac App Store.
- `claude` and `codex` are resolved against an augmented PATH that includes `/opt/homebrew/bin` and `/usr/local/bin`, so the version probe works outside the shell environment Finder provides.
- All providers are file-/API-poll only at the data layer. There is no remote backend.
