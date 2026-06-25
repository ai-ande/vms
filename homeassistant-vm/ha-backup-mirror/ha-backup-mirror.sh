#!/bin/zsh
# Mirror Home Assistant backups (*.tar) from the SMB landing zone to Proton Drive
# via the official Proton Drive CLI.
#
# Runs as akaplan INSIDE the GUI session (a LaunchAgent), so the Proton session
# stored in akaplan's login Keychain is available. Success is only declared once
# each backup is confirmed PRESENT in Proton Drive (the remote is listed and
# checked) — a local copy that never uploads is the silent-failure mode we refuse
# to count as success. A run-record is written either way; on success a heartbeat
# pings Home Assistant (dead-man's-switch), on failure an error POST fires.
#
# NOTE: the exact `proton-drive` subcommands/JSON shape may differ by CLI version
# — verify `proton-drive filesystem list --json` / `... upload` against the
# installed CLI and adjust the two PROTON calls + the jq name extraction below.
emulate -L zsh
setopt no_unset pipe_fail

RR_PROJECT=vms
RR_JOB=ha-backup-mirror
RR_HB_URL="${RR_HB_URL:-http://192.168.20.99:8123/api/webhook/habackup_heartbeat_3kf9q2vtx7}"
RR_ERR_URL="${RR_ERR_URL:-}"     # optional active error webhook; set to enable
export RR_PROJECT RR_JOB RR_HB_URL RR_ERR_URL
. /usr/local/libexec/ajk/run-record.sh

SRC="/Users/Shared/ha-backups"
REMOTE="HomeAssistantBackups"    # Proton Drive destination folder
PROTON="${PROTON_DRIVE:-$(command -v proton-drive 2>/dev/null)}"
[ -n "$PROTON" ] && [ -x "$PROTON" ] || PROTON=/opt/homebrew/bin/proton-drive
JQ=/usr/bin/jq

remote_names() { # echo remote .tar basenames, one per line
  "$PROTON" filesystem list "/$REMOTE" --json 2>/dev/null \
    | "$JQ" -r '(.[]?,.entries[]?,.files[]?)|.name? // empty' 2>/dev/null
}
contains() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# --- preconditions --------------------------------------------------------
[ -d "$SRC" ] || { rr_emit fail "source missing: $SRC"; exit 1; }
[ -r "$SRC" ] || { rr_emit fail "source not readable by $(id -un) (akaplan ACL missing?): $SRC"; exit 1; }
[ -x "$PROTON" ] || { rr_emit fail "proton-drive CLI not found ($PROTON); brew install it and run 'proton-drive auth login' as akaplan"; exit 1; }

typeset -a local_tars
local_tars=( "$SRC"/*.tar(N:t) )
typeset -i src_n=${#local_tars}

# Listing the remote also proves the Proton session/Keychain is alive.
typeset -a remote_tars
remote_tars=( ${(f)"$(remote_names)"} ) || true
if [ -z "${remote_tars[*]:-}" ] && ! "$PROTON" filesystem list "/$REMOTE" --json >/dev/null 2>&1; then
  rr_emit fail "proton-drive list failed — session expired or Keychain locked (is akaplan logged in?)"
  exit 1
fi

# --- upload any local backup not already present remotely ------------------
typeset -i uploaded=0
local f
for f in $local_tars; do
  if ! contains "$f" "${remote_tars[@]:-}"; then
    if "$PROTON" filesystem upload "$SRC/$f" "/$REMOTE/$f" >/dev/null 2>&1; then
      (( uploaded++ ))
    else
      rr_emit fail "upload failed: $f"
      exit 1
    fi
  fi
done

# --- verify every local backup is now present in Proton Drive -------------
remote_tars=( ${(f)"$(remote_names)"} ) || true
typeset -i verified=0 missing=0
for f in $local_tars; do
  if contains "$f" "${remote_tars[@]:-}"; then (( verified++ )); else (( missing++ )); fi
done

extra="$("$JQ" -nc --argjson src $src_n --argjson uploaded $uploaded \
  --argjson verified $verified --argjson missing $missing \
  '{src:$src,uploaded:$uploaded,verified:$verified,missing:$missing}')"

if (( src_n == 0 )); then
  rr_emit warn "no local .tar backups (is HA producing backups?)" "$extra"
  exit 0
fi
if (( missing > 0 )); then
  rr_emit fail "$missing backup(s) NOT present in Proton Drive after upload" "$extra"
  exit 1
fi
rr_emit ok "src=$src_n uploaded=$uploaded verified=$verified" "$extra"
exit 0
