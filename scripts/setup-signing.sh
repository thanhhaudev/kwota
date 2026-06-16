#!/bin/bash
# Detect your Apple Team ID from the login keychain and write Local.xcconfig,
# so signing works without hunting through Xcode menus.
#
#   bash scripts/setup-signing.sh             # auto-detect (asks if several)
#   bash scripts/setup-signing.sh WDCHM35284  # force a specific Team ID
#
# Prereq: sign into your Apple ID once in Xcode → Settings → Accounts.
# A free account works (Xcode makes a "Personal Team") — no paid program needed.
#
# The Team ID is the OU field of your code-signing certificate. The
# "(XXXXXXXXXX)" shown in the certificate name is NOT the Team ID.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
XCCONFIG="$REPO/Local.xcconfig"
WANT="${1:-}"

write_xcconfig() {
  [ -f "$XCCONFIG" ] && cp "$XCCONFIG" "$XCCONFIG.bak"
  cat > "$XCCONFIG" <<EOF
// Local.xcconfig — gitignored. Written by scripts/setup-signing.sh.
// Your Apple Developer team ID; enables code signing for the privileged
// helper / system-cache feature. Leave empty for ad-hoc local signing.
DEVELOPMENT_TEAM = $1
EOF
}

# Collect a deduped list of Team IDs (cert OU) from valid signing identities.
teams=(); labels=()
while IFS= read -r cn; do
  [ -n "$cn" ] || continue
  t="$(security find-certificate -c "$cn" -p 2>/dev/null \
       | openssl x509 -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
       | sed -n 's/^[[:space:]]*OU=//p' | head -1)"
  [ -n "$t" ] || continue
  dup=0
  if [ "${#teams[@]}" -gt 0 ]; then
    for x in "${teams[@]}"; do [ "$x" = "$t" ] && dup=1; done
  fi
  [ "$dup" -eq 1 ] && continue
  teams+=("$t"); labels+=("$cn")
done < <(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')

n="${#teams[@]}"

# --- pick a team ------------------------------------------------------------
choice=""
if [ -n "$WANT" ]; then
  choice="$WANT"
  if [ "$n" -gt 0 ]; then
    found=0; for x in "${teams[@]}"; do [ "$x" = "$WANT" ] && found=1; done
    [ "$found" -eq 0 ] && echo "note: $WANT is not in your keychain; writing it anyway."
  fi
elif [ "$n" -eq 0 ]; then
  echo "No code-signing identity found in your keychain."
  echo
  echo "Add your Apple ID in Xcode → Settings → Accounts (a free account is fine),"
  echo "then re-run:  bash scripts/setup-signing.sh"
  echo "Or build ad-hoc with no team:  echo 'DEVELOPMENT_TEAM =' > Local.xcconfig"
  exit 1
elif [ "$n" -eq 1 ]; then
  choice="${teams[0]}"
  echo "Found one Team ID: ${teams[0]}  (${labels[0]})"
else
  echo "Found multiple Team IDs:"
  for i in "${!teams[@]}"; do printf "  [%d] %s   (%s)\n" "$((i+1))" "${teams[$i]}" "${labels[$i]}"; done
  if [ -t 0 ]; then
    printf "Pick a number [1-%d]: " "$n"; read -r pick
    case "$pick" in (*[!0-9]*|"") pick=0 ;; esac
    choice="${teams[$((pick-1))]:-}"
  fi
  if [ -z "$choice" ]; then
    echo "Re-run with the ID, e.g.:  bash scripts/setup-signing.sh ${teams[0]}"
    exit 2
  fi
fi

# --- write (skip if unchanged) ----------------------------------------------
cur="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$XCCONFIG" 2>/dev/null | head -1)"
if [ "$cur" = "$choice" ]; then
  echo "Local.xcconfig already set to '$choice' — nothing to do."
  exit 0
fi

write_xcconfig "$choice"
echo "Wrote DEVELOPMENT_TEAM = $choice to Local.xcconfig"
[ -f "$XCCONFIG.bak" ] && echo "(previous Local.xcconfig backed up to Local.xcconfig.bak)"
echo "Next:  make run        # build + launch"
echo "       make release-app && open build/Release   # then drag Kwota.app to /Applications"
