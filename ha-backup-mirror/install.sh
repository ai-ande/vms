#!/bin/zsh
# HA Backup Mirror -> Proton Drive. Installed as a gui LaunchAgent for akaplan
# (needs akaplan's GUI session for the Proton login Keychain). Run as root.
#   ./install.sh            deploy + (re)bootstrap into akaplan's GUI session
#   ./install.sh uninstall  bootout + remove plist/script/marker
#   ./install.sh --check    report only, zero mutations
M="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.ajk.ha-backup-mirror
AKUID="$(id -u akaplan 2>/dev/null || true)"
AGENTS="/Users/akaplan/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
SCRIPT=/usr/local/libexec/ajk/ha-backup-mirror.sh
LOGDIR=/usr/local/var/log/ajk/vms/ha-backup-mirror
MARKER=/usr/local/var/lib/ajk/deployed/ha-backup-mirror.json
SRC=/Users/Shared/ha-backups

if [ "$1" = "--check" ]; then
  fail=0
  id akaplan >/dev/null 2>&1 || { echo "DO: akaplan user required"; fail=1; }
  command -v proton-drive >/dev/null 2>&1 || [ -x /opt/homebrew/bin/proton-drive ] || { echo "DO: as akaplan: brew install proton-drive && proton-drive auth login"; fail=1; }
  [ -d "$SRC" ] || { echo "DO: create $SRC (vmhost 0700) + grant akaplan a read ACL"; fail=1; }
  if [ -f "$MARKER" ]; then echo "OK: ha-backup-mirror installed"; else echo "DO: sudo ./install.sh  (then as akaplan: proton-drive auth login)"; fail=1; fi
  [ $fail -eq 0 ] && exit 0 || exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }
[ -n "$AKUID" ] || { echo "DO: akaplan user required"; exit 1; }

if [ "$1" = "uninstall" ]; then
  launchctl bootout gui/$AKUID/$LABEL 2>/dev/null || true
  rm -f "$PLIST" "$MARKER" "$SCRIPT"
  echo "OK: ha-backup-mirror uninstalled"
  exit 0
fi

set -e
install -d -o root -g wheel -m 755 /usr/local/libexec/ajk
install -o root -g wheel -m 755 "$M/ha-backup-mirror.sh" "$SCRIPT"
install -d -o vmhost -g ajklog -m 2775 "$LOGDIR"
install -d -o vmhost -g ajklog -m 2775 /usr/local/var/lib/ajk/deployed
sudo -u akaplan mkdir -p "$AGENTS"
install -o akaplan -g staff -m 644 "$M/$LABEL.plist" "$PLIST"
launchctl bootout gui/$AKUID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$AKUID "$PLIST"

sha="$( (sudo -u akaplan git -C "$M/.." rev-parse HEAD 2>/dev/null) || echo unknown )"
printf '{"sha":"%s","ts":"%s"}\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$MARKER"
chown vmhost:ajklog "$MARKER"
echo "OK: ha-backup-mirror deployed as a gui LaunchAgent for akaplan ($LABEL)"
echo "    NOTE: as akaplan, run once: proton-drive auth login   (stores the Proton session in the login Keychain)"
