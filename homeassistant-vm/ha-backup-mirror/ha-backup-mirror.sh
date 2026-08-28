#!/bin/zsh
# Mirror Home Assistant backups (*.tar) from the SMB landing zone to Proton Drive
# via the official Proton Drive CLI.
#
# Runs as akaplan INSIDE the GUI session (a LaunchAgent), so the Proton session
# stored in akaplan's login Keychain is available. Success is only declared once
# each backup is confirmed PRESENT in Proton Drive — a local copy that never
# uploads is the silent-failure mode we refuse to count as success.
#
# Proton sessions use single-use ROTATING refresh tokens, and every proton-drive
# invocation is a separate process that re-reads the stored session. Back-to-back
# invocations have repeatedly raced that rotation mid-run (one call succeeds, the
# next says "You need to login first", and the session is revoked server-side
# until someone re-logins by hand — see run.history June 25 / Aug 3 / Aug 23).
# Defences, in order of importance:
#   1. steady state (nothing new to upload) is a SINGLE CLI call per day;
#   2. every call goes through pd_run, which paces consecutive calls; and
#   3. pd_run retries once after a settle pause when the error smells like
#      auth/session — rescuing a half-persisted session instead of walking
#      further calls into it.
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
# Proton Drive paths are rooted at /my-files (`/` only lists sections). Full path,
# parents auto-created; the user's /Backups/Home-Assistant lives under /my-files.
REMOTE="/my-files/Backups/Home-Assistant"
# Prefer the installer-pinned CLI (root-owned, checksum-verified, kept current
# by ./install.sh); fall back to whatever is on the box only during transition.
PD_PIN=/usr/local/libexec/ajk/bin/proton-drive
PROTON="${PROTON_DRIVE:-}"
if [ -z "$PROTON" ]; then
  for _cand in "$PD_PIN" "$(command -v proton-drive 2>/dev/null)" /opt/homebrew/bin/proton-drive; do
    [ -n "$_cand" ] && [ -x "$_cand" ] && { PROTON="$_cand"; break; }
  done
fi
[ -n "$PROTON" ] || PROTON="$PD_PIN"
JQ=/usr/bin/jq
PD_ERR=$(/usr/bin/mktemp -t habackup 2>/dev/null) || PD_ERR=/tmp/habackup.err
trap '/bin/rm -f "$PD_ERR" 2>/dev/null' EXIT

typeset -i _pd_calls=0
# pd_run ARGS...: one proton-drive invocation (stdout passes through, stderr ->
# $PD_ERR). Paces consecutive calls so the previous process's session write can
# land, and on an auth-flavoured failure waits and retries ONCE — a genuinely
# dead session fails the same way twice and is reported as such.
pd_run() {
  (( _pd_calls > 0 )) && /bin/sleep 3
  (( _pd_calls += 1 ))
  "$PROTON" "$@" 2>"$PD_ERR" && return 0
  case "$(< "$PD_ERR")" in
    (*[Ll]ogin*|*[Aa]uth*|*nauthor*|*[Ss]ession*)
      /bin/sleep 30
      "$PROTON" "$@" 2>"$PD_ERR" && return 0 ;;
  esac
  return 1
}

# proton-drive list: stdout = JSON, real error -> $PD_ERR, returns CLI exit code.
pd_list()    { pd_run filesystem list "$1" --json; }
# proton-drive names are objects: {"name":{"ok":true,"value":"file.tar"}} — pull .value.
names_from() { "$JQ" -r '(.[]?,.entries?[]?,.files?[]?,.items?[]?)|(.name.value? // .name?)//empty' 2>/dev/null; }
contains()   { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
ensure_remote_dir() {  # create each component of $REMOTE under the root, then confirm
  local acc="" comp
  for comp in ${(s:/:)REMOTE}; do
    pd_run filesystem create-folder "${acc:-/}" "$comp" >/dev/null || true
    acc="$acc/$comp"
  done
  pd_run filesystem list "$REMOTE" --json >/dev/null
}

# --- preconditions --------------------------------------------------------
[ -d "$SRC" ] || { rr_emit fail "source missing: $SRC"; exit 1; }
[ -r "$SRC" ] || { rr_emit fail "source not readable by $(id -un) (akaplan ACL missing?): $SRC"; exit 1; }
[ -x "$PROTON" ] || { rr_emit fail "proton-drive CLI not found ($PROTON); run the vms installer (pins it), then 'proton-drive auth login' as akaplan"; exit 1; }

typeset -a local_tars
local_tars=( "$SRC"/*.tar(N:t) )
typeset -i src_n=${#local_tars}

# --- list the backup folder (doubles as the session probe) -----------------
# One call proves auth AND fetches the listing. Classify a failure from the
# REAL captured error: auth problems get the actionable message; anything else
# is treated as "folder may not exist yet" and we try to create it once.
typeset -a remote_tars
if remote_json="$(pd_list "$REMOTE")"; then
  remote_tars=( ${(f)"$(names_from <<< "$remote_json")"} )
else
  err="$(< "$PD_ERR")"
  case "$err" in
    (*[Ll]ogin*|*[Aa]uth*|*nauthor*)
      rr_emit fail "Proton not authenticated for akaplan — run 'proton-drive auth login' in akaplan's GUI session and keep the login Keychain unlocked. (${err:-need login})"
      exit 1 ;;
  esac
  if ensure_remote_dir; then
    remote_tars=()
  else
    rr_emit fail "could not create $REMOTE in Proton Drive: $(< "$PD_ERR")"
    exit 1
  fi
fi

# --- upload any local backup not already present remotely ------------------
typeset -i uploaded=0
for f in $local_tars; do
  if ! contains "$f" "${remote_tars[@]:-}"; then
    if pd_run filesystem upload "$SRC/$f" "$REMOTE" >/dev/null; then
      (( uploaded++ ))
    else
      rr_emit fail "upload failed: $f — $(< "$PD_ERR")"
      exit 1
    fi
  fi
done

# --- verify every local backup is present in Proton Drive ------------------
# Only re-list after uploads; on a no-op day the first listing IS the proof,
# and skipping the re-list keeps the daily steady state at one CLI call.
# A failed verify listing is reported as ITSELF (the real CLI error), not as
# a bogus "backups not present".
if (( uploaded > 0 )); then
  if remote_json="$(pd_list "$REMOTE")"; then
    remote_tars=( ${(f)"$(names_from <<< "$remote_json")"} )
  else
    rr_emit fail "verify listing failed after upload: $(< "$PD_ERR")"
    exit 1
  fi
fi
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
