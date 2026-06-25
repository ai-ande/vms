#!/bin/zsh
# AdGuard Home headless VM launchd job. Run as root (via the ajk helper, the
# top-level mini-server install.sh, or directly with `sudo ./install.sh`).
#   ./install.sh            deploy + (re)bootstrap
#   ./install.sh uninstall  bootout + remove plist/marker
#   ./install.sh --check    report only, zero mutations
M="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.ajk.vm.adguard
PLIST=/Library/LaunchDaemons/$LABEL.plist
VMX="/Users/Shared/VMs/AdGuard Home.vmwarevm/AdGuard Home.vmx"
LOGDIR=/usr/local/var/log/ajk/vms/vm-adguard
MARKER=/usr/local/var/lib/ajk/deployed/adguard-vm.json

if [ "$1" = "--check" ]; then
  fail=0
  [ -d "/Applications/VMware Fusion.app" ] || { echo "DO: install VMware Fusion"; fail=1; }
  id vmhost >/dev/null 2>&1 || { echo "DO: create standard user 'vmhost'"; fail=1; }
  [ -e "$VMX" ] || { echo "DO: place the VM at /Users/Shared/VMs/AdGuard Home.vmwarevm (chown -R vmhost)"; fail=1; }
  if [ -f "$PLIST" ]; then echo "OK: adguard-vm installed"; else echo "DO: sudo ./install.sh"; fail=1; fi
  [ $fail -eq 0 ] && exit 0 || exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo ./install.sh"; exit 1; }

if [ "$1" = "uninstall" ]; then
  launchctl bootout system/$LABEL 2>/dev/null || true
  rm -f "$PLIST" "$MARKER"
  echo "OK: adguard-vm uninstalled"
  exit 0
fi

set -e
[ -d "/Applications/VMware Fusion.app" ] || { echo "DO: install VMware Fusion"; exit 1; }
id vmhost >/dev/null 2>&1 || { echo "DO: create standard user 'vmhost'"; exit 1; }
[ -e "$VMX" ] || { echo "DO: place the VM at /Users/Shared/VMs/AdGuard Home.vmwarevm (chown -R vmhost)"; exit 1; }

install -d -o vmhost -g staff -m 700 /Users/Shared/VMs
install -o vmhost -g staff -m 700 "$M/start-vm.sh" /Users/Shared/VMs/start-vm.sh
install -d -o vmhost -g ajklog -m 2775 "$LOGDIR"
install -d -o vmhost -g ajklog -m 2775 /usr/local/var/lib/ajk/deployed

cp "$M/$LABEL.plist" "$PLIST"; chown root:wheel "$PLIST"; chmod 644 "$PLIST"
launchctl bootout system/$LABEL 2>/dev/null || true
launchctl bootstrap system "$PLIST"

sha="$( (sudo -u akaplan git -C "$M/.." rev-parse HEAD 2>/dev/null) || git -C "$M/.." rev-parse HEAD 2>/dev/null || echo unknown )"
printf '{"sha":"%s","ts":"%s"}\n' "$sha" "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$MARKER"
chown vmhost:ajklog "$MARKER"
echo "OK: adguard-vm deployed ($LABEL)"
