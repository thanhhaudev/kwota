# Kwota

macOS menu-bar app that tracks Claude Code, Codex, and Antigravity token usage. Reads each provider's own files and APIs — never invokes the CLIs in a way that costs quota. Also toggles `caffeinate` and previews the local Claude cache.

Personal project, single developer. macOS 14.0+, Xcode 16+.

## Build

```bash
make build          # debug
make run            # build + launch
make release-app    # release build → build/Release/Kwota.app
make test           # unit tests (~90s, parallel)
make help           # all targets
```

DerivedData is shared at `~/Library/Developer/Xcode/DerivedData/Kwota-shared`, so multiple worktrees reuse the cache.

## Install

Most features work without any signing setup. To enable **system-cache cleaning** (a root LaunchDaemon installed via `SMAppService`):

1. Copy `Local.xcconfig.example` → `Local.xcconfig` and fill in `DEVELOPMENT_TEAM` with your Apple team ID (Xcode → Settings → Accounts). `make build` auto-creates an empty copy if you skip this — fine for ad-hoc.
2. `make release-app`, drag `build/Release/Kwota.app` to `/Applications`.
3. In the app: Settings → Cache → Privileged helper → Install. Approve in System Settings → General → Login Items & Extensions.

Any Apple ID added to Xcode is enough. The helper's XPC requirement binds to whichever team signs the binary at runtime, so a paid Apple Developer Program is only needed to distribute the app to other Macs.

If `Install` errors after a previous attempt: `sudo sfltool resetbtm` clears the stale registration.

## Tabs

**Usage** — per-provider quota view:
- Claude: 5-hour session, weekly limit, per-model breakdown, Free-plan overlay
- Codex: 5-hour + weekly buckets (`wham/usage`)
- Antigravity: Claude+GPT shared pool, Gemini High, Gemini Low (`GetUserStatus`)

Each provider also gets a session chart with an `avg` reference line (typical % used at the same elapsed time across past completed cycles) and a pace hint ("on track", "above typical", etc.).

**Awake** — toggle `caffeinate` (manual / auto / battery-aware). Below it: a multi-provider activity chart of recent agent replies. Keep-awake reasons are stacked separately — auto (green), manual (blue), battery (orange).

**Cache** — previews `~/.claude/projects/` with size breakdown and an AI safety verdict per row. System-wide icon caches also appear here once the privileged helper is installed.

## How polling works

One self-rescheduling timer (`UsageRefreshCoordinator`):
- Popover open: ~60s
- Popover closed: ~10min
- ±20% jitter on every interval
- A 429 sets a per-provider back-off floor (from `Retry-After`); other providers keep polling

Manual refresh: the chart's refresh button or the "Refresh" shortcut. Still respects back-off + a short anti-spam throttle.

## How token data is collected

Kwota never invokes `claude` or `codex` to read usage (that would burn quota).

- **Claude**: `claude.ai/api/usage` with the cached OAuth token; daily counters + activity timestamps from tailing `~/.claude/projects/**/*.jsonl`.
- **Codex**: same shape against `wham/usage`.
- **Antigravity**: local Connect-RPC `GetUserStatus`; activity from the transcript directory.

The Cache tab's "AI evaluation" is the one feature that does spawn `claude -p` — Anthropic blocks 3rd-party OAuth Bearer access to `/v1/messages`, so the evaluation has to go through the CLI. It uses your normal subscription quota; Kwota tells you when it happens.

## Tests

```bash
make test                          # unit suite
make test-only SUITE=<Name>        # one suite, no rebuild
make test-all                      # include UI tests
```

The UI test target is auto-generated and excluded from `make test` to keep the default run hermetic.

## Notes

- Sandbox-disabled. Launches `/usr/bin/caffeinate`, probes `claude --version`, holds IOKit power assertions, reads `~/.claude/` directly. Distribute as a Developer-ID-signed `.app`, not via the Mac App Store.
- `claude` / `codex` are resolved against an augmented PATH (`/opt/homebrew/bin`, `/usr/local/bin`) so the version probe works outside Finder's shell environment.
- File-/API-poll only at the data layer. No remote backend.
