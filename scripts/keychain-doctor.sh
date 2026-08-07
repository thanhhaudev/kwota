#!/bin/bash
# Kwota keychain doctor — why is the Claude tab stale?
#
# Kwota follows the Claude CLI's token rotations by reading Claude Code's own
# Keychain item. If it cannot, the stored token goes stale, the API 401s, and
# the popover serves hours-old figures. On 2026-08-06 that took most of a day
# to diagnose by hand; this turns it into one command.
#
# What gates that read is the item's PARTITION LIST, not its trusted-application
# list. Being listed as a trusted app is neither necessary nor sufficient — an
# app whose team id is absent from the partition list is refused no matter what
# the app list says, and an app whose team id is present is admitted even when
# the app list names only a long-dead build. Measured both ways; see
# docs/findings/F-005-keychain-interaction-suppression.md.
#
# READ-ONLY, by construction. The probe it builds asks for kSecReturnRef and
# never kSecReturnData, so nothing is decrypted and the consent dialog has no
# reason to fire; interaction is disabled up front regardless. Nothing here
# writes to any keychain item, and it never asks for your password.
#
# Deliberately NOT offered here: a command that adds the partition entry for
# you. `security set-generic-password-partition-list -S` REPLACES the whole
# list rather than appending, so a canned invocation would silently drop
# entries other tools legitimately hold on Claude Code's credential. The
# supported way in is the app's own Grant banner, which routes through macOS's
# consent dialog — system-drawn, unspoofable, and declinable.
#
# Run it any time:  make keychain-doctor   (or: bash scripts/keychain-doctor.sh)

set -uo pipefail

# Resolve the repo from this script's own location — no hardcoded paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# Both overridable, mostly so the failure paths below can be exercised without
# breaking a working machine — and usefully, so you can point this at another
# item or check a team id before that build exists locally.
SERVICE="${KWOTA_KEYCHAIN_SERVICE:-Claude Code-credentials}"
PROBE_SRC="$SCRIPT_DIR/keychain-acl-probe.swift"
PROBE_BIN="$REPO/build/keychain-doctor/aclprobe"

DEVDIR="$(/usr/bin/xcode-select -p 2>/dev/null)"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin${DEVDIR:+:$DEVDIR/usr/bin}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

echo
echo "Kwota keychain doctor"
echo "====================="
echo

# --- 1. which binary's identity actually matters ----------------------------
#
# The partition an app lands in comes from the signature of the binary that
# runs, so ask codesign about the installed app rather than trusting a config
# file. Falls back to build products, then to Local.xcconfig, reporting which
# source answered so a surprising verdict can be traced.

TEAM="${KWOTA_TEAM:-}"
TEAM_SRC=""
[ -n "$TEAM" ] && TEAM_SRC="KWOTA_TEAM override"

[ -z "$TEAM" ] && for candidate in \
    "/Applications/Kwota.app" \
    "$REPO/build/Release/Kwota.app" \
    "$HOME/Library/Developer/Xcode/DerivedData/Kwota-shared/Build/Products/Debug/Kwota.app"
do
    [ -d "$candidate" ] || continue
    t="$(/usr/bin/codesign -dv "$candidate" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
    if [ -n "$t" ] && [ "$t" != "not set" ]; then
        TEAM="$t"; TEAM_SRC="$candidate"
        break
    fi
    if [ -z "$TEAM_SRC" ]; then TEAM_SRC="$candidate"; fi
done

if [ -z "$TEAM" ] && [ -f "$REPO/Local.xcconfig" ]; then
    t="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM/{gsub(/[[:space:]]/,"",$2); print $2}' "$REPO/Local.xcconfig")"
    if [ -n "$t" ]; then TEAM="$t"; TEAM_SRC="$REPO/Local.xcconfig (no signed app found)"; fi
fi

if [ -z "$TEAM" ]; then
    bad "No Developer-ID team could be determined."
    note "Checked the installed app, build products, and Local.xcconfig."
    note "An ad-hoc signed build has no team id and is partitioned by cdhash,"
    note "so it loses access on every rebuild. Run: make signing-setup"
    echo
    exit 1
fi
ok "Signing team: $TEAM"
note "from $TEAM_SRC"
echo

# --- 2. read the item's ACL --------------------------------------------------
#
# Compiled fresh into build/ rather than shipped: it is a few hundred
# milliseconds, and a throwaway binary that is never granted anything cannot
# accumulate the ACL debris that earlier hand-probes did.

if [ ! -x "$PROBE_BIN" ] || [ "$PROBE_SRC" -nt "$PROBE_BIN" ]; then
    mkdir -p "$(dirname "$PROBE_BIN")"
    if ! swiftc -O -o "$PROBE_BIN" "$PROBE_SRC" 2>/dev/null; then
        bad "Could not build the ACL probe from $PROBE_SRC"
        note "Needs the Xcode toolchain: xcode-select --install"
        echo
        exit 1
    fi
fi

ACL="$("$PROBE_BIN" "$SERVICE" 2>&1)"
if ! grep -q '^item:' <<<"$ACL"; then
    warn "No '$SERVICE' item in your login keychain."
    note "That means Claude Code is not signed in on this machine, so there is"
    note "nothing for Kwota to follow. Run: claude login"
    echo
    exit 0
fi
ok "Found keychain item: $SERVICE"
echo

# --- 3. the verdict ----------------------------------------------------------

PARTS="$(awk '/ACLAuthorizationPartitionID/{print}' <<<"$ACL" \
        | grep -oE '"[0-9a-f]{40,}"' | tr -d '"' \
        | python3 -c 'import sys,re
h=sys.stdin.read().strip()
if h: print("\n".join(re.findall(r"<string>(.*?)</string>", bytes.fromhex(h).decode())))' 2>/dev/null)"

echo "Partition list (this is the gate):"
if [ -z "$PARTS" ]; then
    note "(none readable)"
else
    while IFS= read -r p; do note "$p"; done <<<"$PARTS"
fi
echo

if grep -qx "teamid:$TEAM" <<<"$PARTS"; then
    ok "teamid:$TEAM is present — Kwota can read the CLI credential."
    note "Nothing to do. If the Claude tab is still stale, the cause is"
    note "elsewhere; check: log show --predicate 'subsystem == \"com.thanhhaudev.kwota\""
    note "AND category == \"credential-diag\"' --last 1h --info"
    STATUS=0
else
    bad "teamid:$TEAM is NOT in the partition list — the read will be refused."
    note ""
    note "Fix it from inside the app, not from the shell:"
    note "  1. Open Kwota. The Claude tab shows a \"Keychain access needed\" banner."
    note "  2. Press Grant."
    note "  3. In the macOS dialog choose \"Always Allow\" — NOT plain \"Allow\"."
    note ""
    note "\"Allow\" decrypts once and persists nothing, so the banner returns at"
    note "the next token rotation. \"Always Allow\" writes the partition entry"
    note "and survives every rotation and every re-signing."
    STATUS=1
fi
echo

# Printed last, and framed as context, because reading this list top-down is
# what sent the original investigation down a blind alley for a day.
echo "Trusted applications (informational — NOT what gates the read):"
grep '^   - ' <<<"$ACL" | sed 's/^   - /    /' || note "(none)"
echo

exit $STATUS
