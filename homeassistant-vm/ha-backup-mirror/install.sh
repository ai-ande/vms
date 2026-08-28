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

# Pinned Proton Drive CLI (session-handling fixes ship often; stay current
# deliberately, not by hand). Version + SHA-512 come from
# https://proton.me/download/drive/cli/ — update BOTH together.
PD_VERSION=0.8.0
PD_SHA512=1483a2fa6afe7a49abdc34f66420b87e0a5d48d236f6f4a79eae7f7d76dc3a6beebedcde5e229ce5fdef42450ada41bbcc02161a64afb473bcaa4fda938c7329
PD_URL="https://proton.me/download/drive/cli/${PD_VERSION}/darwin-arm64/proton-drive"
PD_BIN=/usr/local/libexec/ajk/bin/proton-drive

pd_sha() { shasum -a 512 "$1" 2>/dev/null | awk '{print $1}'; }

# Idempotent: correct binary already pinned -> no network. Otherwise download,
# verify the checksum BEFORE install, and never leave a half-written binary.
# Failure is a WARN, not fatal: the mirror script falls back to any existing CLI.
ensure_proton_cli() {
  if [ -x "$PD_BIN" ] && [ "$(pd_sha "$PD_BIN")" = "$PD_SHA512" ]; then
    return 0
  fi
  local tmp; tmp=$(mktemp -t protoncli) || return 1
  if curl -fsSL --max-time 300 -o "$tmp" "$PD_URL" && [ "$(pd_sha "$tmp")" = "$PD_SHA512" ]; then
    install -d -o root -g wheel -m 755 /usr/local/libexec/ajk/bin
    install -o root -g wheel -m 755 "$tmp" "$PD_BIN"
    rm -f "$tmp"
    echo "OK: proton-drive CLI $PD_VERSION pinned at $PD_BIN"
  else
    rm -f "$tmp"
    echo "WARN: could not fetch/verify proton-drive $PD_VERSION; keeping existing CLI"
    return 1
  fi
}

if [ "$1" = "--check" ]; then
  fail=0
  id akaplan >/dev/null 2>&1 || { echo "DO: akaplan user required"; fail=1; }
  if [ -x "$PD_BIN" ] && [ "$(pd_sha "$PD_BIN")" = "$PD_SHA512" ]; then
    echo "OK: proton-drive CLI $PD_VERSION pinned"
  else
    echo "DO: sudo ./install.sh downloads the pinned proton-drive $PD_VERSION; then as akaplan: proton-drive auth login"
    fail=1
  fi
  [ -d "$SRC" ] || { echo "DO: create $SRC (vmhost 0700) + grant akaplan a read ACL"; fail=1; }
  if [ -f "$MARKER" ]; then echo "OK: ha-backup-mirror installed"; else echo "DO: sudo ./install.sh  (then as akaplan: proton-drive auth login)"; fail=1; fi
  [ $fail -eq 0 ] && exit 0 || exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }
[ -n "$AKUID" ] || { echo "DO: akaplan user required"; exit 1; }

if [ "$1" = "uninstall" ]; then
  launchctl bootout gui/$AKUID/$LABEL 2>/dev/null || true
  rm -f "$PLIST" "$MARKER" "$SCRIPT" "$PD_BIN"
  echo "OK: ha-backup-mirror uninstalled"
  exit 0
fi

set -e
ensure_proton_cli || true
install -d -o root -g wheel -m 755 /usr/local/libexec/ajk
install -o root -g wheel -m 755 "$M/ha-backup-mirror.sh" "$SCRIPT"
install -d -o vmhost -g ajklog -m 2775 "$LOGDIR"
install -d -o vmhost -g ajklog -m 2775 /usr/local/var/lib/ajk/deployed
sudo -u akaplan mkdir -p "$AGENTS"
install -o akaplan -g staff -m 644 "$M/$LABEL.plist" "$PLIST"
launchctl bootout gui/$AKUID/$LABEL 2>/dev/null || true
_i=0; while launchctl print gui/$AKUID/$LABEL >/dev/null 2>&1 && [ $_i -lt 30 ]; do sleep 0.2; _i=$((_i+1)); done
launchctl bootstrap gui/$AKUID "$PLIST" 2>/dev/null \
  || launchctl kickstart -k gui/$AKUID/$LABEL 2>/dev/null \
  || echo "WARN: could not (re)load $LABEL"

sha="$( (sudo -u akaplan git -C "$M/.." rev-parse HEAD 2>/dev/null) || echo unknown )"
printf '{"sha":"%s","ts":"%s"}\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$MARKER"
chown vmhost:ajklog "$MARKER"
echo "OK: ha-backup-mirror deployed as a gui LaunchAgent for akaplan ($LABEL)"
echo "    NOTE: first install only — as akaplan, run once: proton-drive auth login"
