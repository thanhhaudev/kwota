#!/bin/bash
# Install (or remove) the Kwota signing auto-refresh LaunchAgent.
#
# Generates a per-machine LaunchAgent that runs scripts/refresh-signing.sh
# weekly (and at each login). All absolute paths are filled in for the
# current user, so this works from any clone location and any account.
#
#   bash scripts/install-signing-refresh.sh            # install
#   bash scripts/install-signing-refresh.sh uninstall  # remove

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REFRESH="$SCRIPT_DIR/refresh-signing.sh"
LABEL="com.thanhhaudev.kwota.signing-refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

case "${1:-install}" in
  uninstall)
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL."
    exit 0 ;;
  install) ;;
  *) echo "usage: $0 [install|uninstall]"; exit 2 ;;
esac

[ -f "$REFRESH" ] || { echo "error: $REFRESH not found"; exit 1; }
chmod +x "$REFRESH"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REFRESH</string>
    </array>
    <!-- Weekly check: Monday 10:00. launchd runs a missed slot on next wake. -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>1</integer>
        <key>Hour</key><integer>10</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <!-- Also a cheap cert-check at each login. -->
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/kwota-signing-refresh.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/kwota-signing-refresh.err.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "Installed $LABEL"
echo "  runs:  weekly (Mon 10:00) + at each login"
echo "  guards: /Applications/Kwota.app (re-signs before its cert expires)"
echo "  log:   ~/Library/Logs/kwota-signing-refresh.log"
echo "  remove: bash scripts/install-signing-refresh.sh uninstall"
