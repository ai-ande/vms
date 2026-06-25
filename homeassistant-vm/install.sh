#!/bin/zsh
# Home Assistant headless VM launchd job. Run as root (via the ajk helper, the
# top-level mini-server install.sh, or directly with `sudo ./install.sh`).
#   ./install.sh            deploy + (re)bootstrap
#   ./install.sh uninstall  bootout + remove plist/marker
#   ./install.sh --check    report only, zero mutations
M="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.ajk.vm.homeassistant
PLIST=/Library/LaunchDaemons/$LABEL.plist
VMX="/Users/Shared/VMs/Home Assistant.vmwarevm/Home Assistant.vmx"
LOGDIR=/usr/local/var/log/ajk/vms/vm-homeassistant
MARKER=/usr/local/var/lib/ajk/deployed/homeassistant-vm.json

if [ "$1" = "--check" ]; then
  fail=0
  [ -d "/Applications/VMware Fusion.app" ] || { echo "DO: install VMware Fusion"; fail=1; }
  id vmhost >/dev/null 2>&1 || { echo "DO: create standard user 'vmhost'"; fail=1; }
  [ -e "$VMX" ] || { echo "DO: place the VM at /Users/Shared/VMs/Home Assistant.vmwarevm (chown -R vmhost)"; fail=1; }
  if [ -f "$PLIST" ]; then echo "OK: homeassistant-vm installed"; else echo "DO: sudo ./install.sh"; fail=1; fi
  [ $fail -eq 0 ] && exit 0 || exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }

if [ "$1" = "uninstall" ]; then
  launchctl bootout system/$LABEL 2>/dev/null || true
  rm -f "$PLIST" "$MARKER"
  echo "OK: homeassistant-vm uninstalled"
  exit 0
fi

set -e
[ -d "/Applications/VMware Fusion.app" ] || { echo "DO: install VMware Fusion"; exit 1; }
id vmhost >/dev/null 2>&1 || { echo "DO: create standard user 'vmhost'"; exit 1; }
[ -e "$VMX" ] || { echo "DO: place the VM at /Users/Shared/VMs/Home Assistant.vmwarevm (chown -R vmhost)"; exit 1; }

install -d -o vmhost -g staff -m 700 /Users/Shared/VMs
install -o vmhost -g staff -m 700 "$M/start-vm.sh" /Users/Shared/VMs/start-vm.sh
install -d -o vmhost -g ajklog -m 2775 "$LOGDIR"
install -d -o vmhost -g ajklog -m 2775 /usr/local/var/lib/ajk/deployed

cp "$M/$LABEL.plist" "$PLIST"; chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout system/$LABEL 2>/dev/null || true
_i=0; while launchctl print system/$LABEL >/dev/null 2>&1 && [ $_i -lt 30 ]; do sleep 0.2; _i=$((_i+1)); done
launchctl bootstrap system "$PLIST" 2>/dev/null \
  || launchctl kickstart -k system/$LABEL 2>/dev/null \
  || echo "WARN: could not (re)load $LABEL"

sha="$( (sudo -u akaplan git -C "$M/.." rev-parse HEAD 2>/dev/null) || git -C "$M/.." rev-parse HEAD 2>/dev/null || echo unknown )"
printf '{"sha":"%s","ts":"%s"}\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$MARKER"
chown vmhost:ajklog "$MARKER"
echo "OK: homeassistant-vm deployed ($LABEL)"
