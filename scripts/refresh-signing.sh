#!/bin/bash
# Kwota signing auto-refresh.
#
# Re-signs the installed /Applications/Kwota.app before its embedded
# development certificate expires, so the app keeps launching (and the
# privileged helper keeps loading) without you rebuilding by hand.
#
# A development signature carries no secure timestamp, so once its leaf
# certificate expires (typically ~1 year out) macOS refuses to launch the
# app and launchd refuses to load the privileged-helper daemon. Rebuilding
# re-signs with a freshly renewed certificate (Xcode automatic signing).
#
# Dev builds from `make run` are intentionally NOT touched — those get a
# fresh signature every time you rebuild during development. This only
# guards the long-lived install in /Applications.
#
# Install it to run weekly:  bash scripts/install-signing-refresh.sh
# Run it by hand any time:    bash scripts/refresh-signing.sh

set -uo pipefail

# Resolve the repo from this script's own location — no hardcoded paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="/Applications/Kwota.app"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Kwota-shared"   # matches the Makefile
THRESHOLD_DAYS=30
LOG="$HOME/Library/Logs/kwota-signing-refresh.log"
LOCKDIR="/tmp/kwota-signing-refresh.lockd"

# LaunchAgents start with a bare PATH; add the Xcode toolchain explicitly.
DEVDIR="$(/usr/bin/xcode-select -p 2>/dev/null)"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin${DEVDIR:+:$DEVDIR/usr/bin}"

log()    { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }

# --- single-instance lock (the rebuild is slow) -----------------------------
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    rmdir "$LOCKDIR" 2>/dev/null; mkdir "$LOCKDIR" 2>/dev/null || { log "lock busy; skip"; exit 0; }
  else
    log "another run in progress; skip"; exit 0
  fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# --- 1. installed yet? ------------------------------------------------------
if [ ! -d "$APP" ]; then
  log "no $APP (not installed yet) — nothing to guard"
  exit 0
fi

# --- 2. does it still verify, and is the cert far from expiry? --------------
needs_refresh=0; reason=""
if ! codesign --verify --strict "$APP" >/dev/null 2>&1; then
  needs_refresh=1; reason="signature no longer verifies"
else
  TMPCERT="$(mktemp -t kwota_cert)"; rm -f "${TMPCERT}0"
  codesign -dvvv --extract-certificates="$TMPCERT" "$APP" >/dev/null 2>&1
  if [ -f "${TMPCERT}0" ]; then
    enddate="$(openssl x509 -inform DER -in "${TMPCERT}0" -noout -enddate 2>/dev/null | cut -d= -f2)"
    # -checkend exits non-zero if the cert WILL expire within N seconds.
    if openssl x509 -inform DER -in "${TMPCERT}0" -noout -checkend $(( THRESHOLD_DAYS * 86400 )) >/dev/null 2>&1; then
      log "OK — cert good (expires ${enddate:-?}, > ${THRESHOLD_DAYS}d away)"
    else
      needs_refresh=1; reason="cert expires within ${THRESHOLD_DAYS}d (on ${enddate:-?})"
    fi
  else
    log "warn: could not read embedded cert; refreshing to be safe"
    needs_refresh=1; reason="cert unreadable"
  fi
  rm -f "${TMPCERT}" "${TMPCERT}0"
fi

if [ "$needs_refresh" -eq 0 ]; then exit 0; fi
log "REFRESH triggered: $reason"

# --- 3. rebuild Release (Xcode renews the cert via automatic signing) -------
cd "$REPO" || { log "ERROR: repo not found at $REPO"; notify "Kwota refresh failed" "Repo missing at $REPO"; exit 1; }

log "building Release…"
if ! xcodebuild -project Kwota/Kwota.xcodeproj -scheme Kwota -configuration Release \
     -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
     -allowProvisioningUpdates build >>"$LOG" 2>&1; then
  log "ERROR: build failed (see lines above). Keeping existing app."
  notify "Kwota refresh failed" "Build failed — run 'make release-app' in the repo by hand."
  exit 1
fi

BUILT="$(xcodebuild -project Kwota/Kwota.xcodeproj -scheme Kwota -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
NEWAPP="$BUILT/Kwota.app"

if [ ! -d "$NEWAPP" ] || ! codesign --verify --strict "$NEWAPP" >/dev/null 2>&1; then
  log "ERROR: fresh build missing or unsigned at $NEWAPP — aborting swap"
  notify "Kwota refresh failed" "Fresh build did not verify; existing app untouched."
  exit 1
fi

# --- 4. quit, swap the bundle, relaunch -------------------------------------
was_running=0
if pgrep -x Kwota >/dev/null 2>&1; then
  was_running=1
  osascript -e 'tell application "Kwota" to quit' >/dev/null 2>&1
  sleep 2; pkill -x Kwota 2>/dev/null
fi

rm -rf "$APP.old"
mv "$APP" "$APP.old" 2>/dev/null
if cp -R "$NEWAPP" "$APP"; then
  rm -rf "$APP.old"
  log "installed freshly signed build into $APP"
else
  log "ERROR: copy failed — restoring previous app (is it in /Applications and are you an admin?)"
  [ -d "$APP.old" ] && mv "$APP.old" "$APP"
  notify "Kwota refresh failed" "Could not replace /Applications/Kwota.app"
  exit 1
fi

[ "$was_running" -eq 1 ] && { open "$APP"; log "relaunched Kwota"; }
log "DONE — signing refreshed"
notify "Kwota re-signed" "Signature refreshed; good for another year."
# Note: if the privileged helper was installed, macOS may ask you to
# re-approve it once in System Settings → Login Items after a bundle swap.
