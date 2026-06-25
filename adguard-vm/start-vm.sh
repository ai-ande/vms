#!/bin/sh
# Start a headless VMware Fusion VM (idempotent) and record the outcome.
# RR_PROJECT and RR_JOB are supplied by the launchd plist environment.
VMX="$1"
VMRUN="/Applications/VMware Fusion.app/Contents/Public/vmrun"
[ -f /usr/local/libexec/ajk/run-record.sh ] && . /usr/local/libexec/ajk/run-record.sh
emit() { command -v rr_emit >/dev/null 2>&1 && rr_emit "$@" || true; }

# Already running? Do nothing — and never touch a live lock.
if "$VMRUN" -T fusion list | grep -qF "$VMX"; then
  emit ok "already running"
  exit 0
fi

# Clear stale locks from an unclean shutdown, then start headless.
find "$(dirname "$VMX")" -maxdepth 1 -name '*.lck' -exec rm -rf {} + 2>/dev/null

"$VMRUN" -T fusion start "$VMX" nogui
rc=$?
if [ "$rc" -eq 0 ]; then
  emit ok "started"
  exit 0
fi
emit fail "vmrun start failed (rc=$rc)"
exit "$rc"
