#!/bin/zsh
# Mirror Home Assistant backups (*.tar) from the SMB landing zone to Proton Drive
# via the official Proton Drive CLI.
#
# Runs as akaplan INSIDE the GUI session (a LaunchAgent), so the Proton session
# stored in akaplan's login Keychain is available. Success is only declared once
# each backup is confirmed PRESENT in Proton Drive — a local copy that never
# uploads is the silent-failure mode we refuse to count as success.
#
# On failure we record the ACTUAL proton-drive error (captured stderr), never a
# guess, so the dashboard shows the real reason. The folder is created if absent.
emulate -L zsh
setopt no_unset pipe_fail

RR_PROJECT=vms
RR_JOB=ha-backup-mirror
RR_HB_URL="${RR_HB_URL:-http://192.168.20.99:8123/api/webhook/habackup_heartbeat_3kf9q2vtx7}"
RR_ERR_URL="${RR_ERR_URL:-}"     # optional active error webhook; set to enable
export RR_PROJECT RR_JOB RR_HB_URL RR_ERR_URL
. /usr/local/libexec/ajk/run-record.sh

SRC="/Users/Shared/ha-backups"
REMOTE="/Backups/Home-Assistant"  # Proton Drive destination (full path; parents auto-created)
PROTON="${PROTON_DRIVE:-$(command -v proton-drive 2>/dev/null)}"
[ -n "$PROTON" ] && [ -x "$PROTON" ] || PROTON=/opt/homebrew/bin/proton-drive
JQ=/usr/bin/jq
PD_ERR=$(/usr/bin/mktemp -t habackup 2>/dev/null) || PD_ERR=/tmp/habackup.err
trap '/bin/rm -f "$PD_ERR" 2>/dev/null' EXIT

# proton-drive list: stdout = JSON, real error -> $PD_ERR, returns CLI exit code.
pd_list()    { "$PROTON" filesystem list "$1" --json 2>"$PD_ERR"; }
names_from() { "$JQ" -r '(.[]?,.entries[]?,.files[]?,.items[]?)|.name? // empty' 2>/dev/null; }
contains()   { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
ensure_remote_dir() {  # create each component of $REMOTE under the root, then confirm
  local acc="" comp
  for comp in ${(s:/:)REMOTE}; do
    "$PROTON" filesystem create-folder "${acc:-/}" "$comp" >/dev/null 2>"$PD_ERR" || true
    acc="$acc/$comp"
  done
  "$PROTON" filesystem list "$REMOTE" --json >/dev/null 2>"$PD_ERR"
}

# --- preconditions --------------------------------------------------------
[ -d "$SRC" ] || { rr_emit fail "source missing: $SRC"; exit 1; }
[ -r "$SRC" ] || { rr_emit fail "source not readable by $(id -un) (akaplan ACL missing?): $SRC"; exit 1; }
[ -x "$PROTON" ] || { rr_emit fail "proton-drive CLI not found ($PROTON); brew install it + 'proton-drive auth login' as akaplan"; exit 1; }

typeset -a local_tars
local_tars=( "$SRC"/*.tar(N:t) )
typeset -i src_n=${#local_tars}

# --- prove the Proton session works (list root) — record the REAL error ----
if ! pd_list "/" >/dev/null; then
  err="$(< "$PD_ERR")"
  case "$err" in
    (*[Ll]ogin*|*[Aa]uth*|*nauthor*)
      rr_emit fail "Proton not authenticated for akaplan — run 'proton-drive auth login' in akaplan's GUI session and keep the login Keychain unlocked. (${err:-need login})" ;;
    (*)
      rr_emit fail "proton-drive could not reach Proton Drive: ${err:-unknown error}" ;;
  esac
  exit 1
fi

# --- list the backup folder; create it once if it doesn't exist yet --------
typeset -a remote_tars
if remote_json="$(pd_list "$REMOTE")"; then
  remote_tars=( ${(f)"$(names_from <<< "$remote_json")"} )
elif ensure_remote_dir; then
  remote_tars=()
else
  rr_emit fail "could not create $REMOTE in Proton Drive: $(< "$PD_ERR")"
  exit 1
fi

# --- upload any local backup not already present remotely ------------------
typeset -i uploaded=0
local f
for f in $local_tars; do
  if ! contains "$f" "${remote_tars[@]:-}"; then
    if "$PROTON" filesystem upload "$SRC/$f" "$REMOTE" >/dev/null 2>"$PD_ERR"; then
      (( uploaded++ ))
    else
      rr_emit fail "upload failed: $f — $(< "$PD_ERR")"
      exit 1
    fi
  fi
done

# --- verify every local backup is now present in Proton Drive -------------
remote_tars=( ${(f)"$(pd_list "$REMOTE" | names_from)"} )
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
