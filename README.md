# Kwota

Token usage tracker for AI coding assistants. Lives in the menu bar; toggles `caffeinate` and previews the local Claude cache.

Personal project, single developer. macOS 14.0+, Xcode 16+.

## Providers

| Provider    | Tracked                                              | Source                                                                          |
| ----------- | ---------------------------------------------------- | ------------------------------------------------------------------------------- |
| Claude Code | 5-hour session, weekly limit, per-model breakdown    | `claude.ai/api/usage` (OAuth) + `~/.claude/projects/**/*.jsonl`                 |
| Codex       | 5-hour + weekly buckets                              | `wham/usage`                                                                    |
| Antigravity | Credit pools + per-model quotas                      | local Connect-RPC `GetUserStatus`                                               |

## Build

```bash
make build          # debug
make run            # build + launch
make release-app    # release build → build/Release/Kwota.app
make test           # unit tests (~90s, parallel)
make help           # all targets
```

DerivedData is shared at `~/Library/Developer/Xcode/DerivedData/Kwota-shared`.

## Install

The app runs without signing setup. To enable **system-cache cleaning** (needs a root helper):

1. Set `DEVELOPMENT_TEAM` in `Local.xcconfig` — your Apple team ID from Xcode → Settings → Accounts. No paid Apple Developer Program needed. `make build` creates `Local.xcconfig` from `.example` if missing.
2. `make release-app`, drag `build/Release/Kwota.app` to `/Applications`.
3. Settings → Cache → Privileged helper → Install. Approve in System Settings → General → Login Items & Extensions.

If `Install` errors after a previous attempt: `sudo sfltool resetbtm`.

## Tabs

**Usage** — per-provider quota view (see the Providers table above). Each provider gets a session chart with an `avg` reference line (typical % at the same point in past cycles) and a pace hint ("on track", "above typical", etc.). A Free-plan overlay shows for Claude accounts with no paid subscription.

**Awake** — toggle `caffeinate` (manual / auto / battery-aware). Below it: a multi-provider activity chart of recent agent replies. Keep-awake reasons are stacked separately — auto (green), manual (blue), battery (orange).

**Cache** — previews `~/.claude/projects/` with size breakdown and an AI evaluation per row. System-wide icon caches also appear here once the privileged helper is installed.

## How polling works

One self-rescheduling timer:
- Popover open: ~60s
- Popover closed: ~10min
- ±20% jitter on every interval
- A 429 sets a per-provider back-off floor (from `Retry-After`); other providers keep polling

Manual refresh (chart button or "Refresh" shortcut) respects the same back-off and a short anti-spam throttle.

## How token data is collected

Kwota never invokes `claude` or `codex` to read usage — that would burn quota.

The Cache tab's "AI evaluation" is the one feature that does spawn `claude -p` (Anthropic blocks 3rd-party API access). It uses your normal subscription quota; Kwota tells you when it happens.

## How the avg line is computed

Kwota stores raw `(timestamp, % used)` samples and segments them into completed cycles — 5-hour cycles for the session view, 7-day cycles for the weekly view.

A cycle ends when the next sample's value drops by ≥5 percentage points (smaller drops are server-side rounding noise; a real reset is ~95+). The trailing in-progress cycle is excluded so the line compares against finished history, not a partial sample.

For any elapsed time `t` in the current cycle, `avg(t)` is the mean of `value(t)` across past cycles — "what % were you typically at, this far in". The chart draws it as a reference line alongside the current cycle's series; the pace hint reads "on track" / "above typical" / etc. by comparing the current point against `avg(t)`.

## How the session/week chart renders

Claude and Codex share the same chart. Two views:

- **Session** — bars per hour of the current 5-hour cycle. The latest bar is the focal bar; an extra ghost bar projects the next hour from the last 2-3 deltas.
- **Week** — bars per day of the current 7-day cycle.

Each bar's color comes from its own value — green → yellow → red as it approaches the limit. The session's focal bar adds a slow "warm pulse" when the pace is heavy. The dashed green `avg` line (toggleable) sits over the bars. Before the first successful fetch, the chart shows "Waiting for first fetch…".

## Tests

```bash
make test                          # unit suite
make test-only SUITE=<Name>        # one suite, no rebuild
make test-all                      # include UI tests
```

The UI test target is excluded from `make test` by default.

## Notes

- Sandbox-disabled. Launches `/usr/bin/caffeinate`, probes `claude --version`, holds IOKit power assertions, reads `~/.claude/` directly. Distribute as a Developer-ID-signed `.app`, not via the Mac App Store.
- `claude` / `codex` are resolved against an augmented PATH that includes `/opt/homebrew/bin` and `/usr/local/bin`.
- No remote backend — only reads provider files and APIs.
