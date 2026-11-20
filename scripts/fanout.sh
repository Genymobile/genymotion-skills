#!/usr/bin/env bash
# fanout.sh — start several Genymotion SaaS instances in parallel, connect ADB
# on distinct ports, and stop them all reliably.
#
# Contract: references/parallel-reference.md and references/configuration.md.
# Run it from the project directory: it reads ./.genymotion.json and writes its
# state under ./.genymotion/runs/. Standard output carries exactly one JSON
# object; progress and errors go to standard error.

# Bash 4.4 or later: before 4.4, "set -u" treats an empty array as unbound.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
  { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "fanout.sh: Bash 4.4 or later is required (found ${BASH_VERSION:-unknown}). On macOS: brew install bash" >&2
  if [ "${1:-}" = "start" ]; then
    printf '%s\n' '{"run_id": null, "adb": null, "instances": [], "error": "Bash 4.4 or later is required"}'
  else
    printf '%s\n' '{"run_id": null, "instances": [], "error": "Bash 4.4 or later is required"}'
  fi
  exit 2
fi

set -euo pipefail
# A closed output pipe must not kill the script: writes fail instead, and a
# start whose result cannot be printed tears its run down (exit 5).
trap '' PIPE

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly BOOT_POLLS=10          # boot polls at most (SKILL.md)
readonly STOP_POLLS=12          # stop checks at most
readonly MAX_EXTRA_PORTS=20     # busy ADB ports skipped at most per run
readonly ADB_CHECKS=5           # "adb devices" checks at most
readonly START_CALL_WAIT=40     # seconds a signal handler waits for an in-flight start call
readonly ACTIVE_START_WAIT=240  # seconds "stop" waits for a running "start" of the same run
readonly ADB_DEVICES_TIMEOUT=20 # seconds an "adb devices" check may take before it is killed
# Time limits of the gmsaas calls. "instances stop" waits up to 30 s for the ADB
# disconnect before its HTTP call; "instances adbconnect" has its own 60 s limit.
readonly GMSAAS_CALL_LIMIT=60   # instances list|get|start, config get, adb start
readonly GMSAAS_SLOW_CALL_LIMIT=90  # instances stop, instances adbconnect
readonly RECORD_MAX_AGE_DAYS=30 # records of runs verified stopped are deleted after this
readonly DEFAULT_DURATION=60    # minutes
readonly DEFAULT_MAX_INSTANCES=5
readonly DEFAULT_PREFIX=agent
readonly DEFAULT_BASE_PORT=15555
readonly DEFAULT_POLL_INTERVAL=30
readonly DEFAULT_STOP_POLL_INTERVAL=10
readonly STARTING_STATES=" CREATING STARTING OFFLINE BOOTING UNKNOWN "
# States of an instance on its way out (gmsaas). A stop is not re-issued for them.
# OFFLINE is also a starting state: a stop is re-issued for it (harmless).
readonly LEAVING_STATES=" STOPPING STOPPED DELETING "
readonly FAILURE_STATUSES=" START_FAILED BOOT_FAILED TIMEOUT ADB_FAILED "
readonly FINAL_STATUSES=" STOPPED START_FAILED BOOT_FAILED TIMEOUT ADB_FAILED "
readonly UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly RUN_ID_RE='^[0-9]{14}-[0-9a-f]{8}$'
readonly PREFIX_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$'

PROJECT_DIR="$PWD"
CONFIG_FILE="$PROJECT_DIR/.genymotion.json"
RUNS_DIR="$PROJECT_DIR/.genymotion/runs"

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
CMD=""
RUN_ID=""
OUTPUT_DONE=0       # the one JSON object was printed (or its printing was attempted)
START_ACTIVE=0      # a start is in progress: any abnormal exit must tear it down
STARTED_ANY=0       # a start call was issued
SLEEP_PID=""
GM_PID="" GM_KIND="" GM_INDEX="" GM_WD="" ADB_PID="" ADB_WD=""
GM_LIMIT_OVERRIDE=""  # GENYMOTION_CALL_TIMEOUT (tests only): one limit for every gmsaas call
WD_PID=""
WORK_DIR=""
PID_FILE=""
HAVE_JQ=0
ADB_BIN=""
PREFIX="" RECIPE="" DURATION="" COUNT="" MIN="" BASE_PORT="" MAX_INSTANCES=""
POLL_INTERVAL="" STOP_POLL_INTERVAL=""
GM_OUT="" GM_RC=0 GM_ERR_MSG=""
# Instances (index i is instance number i+1 for start). E_RUN: run id of the entry (stop only).
# I_VSTOP: 1 when the stop of the entry was verified (recorded as "stop_verified").
# I_SEEN: 1 once the instance appeared in a list (start only).
I_NAME=() I_UUID=() I_SERIAL=() I_STATUS=() I_LIVE=() E_RUN=() I_VSTOP=() I_SEEN=()
declare -A LIVE_STATE=() LIVE_SERIAL=() LIVE_BY_NAME=()
LIVE_VALID=0        # the last live_list succeeded
LOOKUP_DONE=0       # stop: the lookup of the runs' instances by name ran on a successful list
STOP_CALLS_SENT=0   # stop calls sent in this invocation
STOP_REMAINING=()
declare -A STOP_TARGETS=()  # UUIDs handled by the last stop_and_verify
declare -A STOP_GONE=()     # UUIDs the last stop_and_verify verified gone
declare -A KNOWN_GONE=()    # UUIDs a run record already gives as verified stopped
declare -A STOP_OBS=()      # last state the last stop_and_verify saw for a target
GET_STATE=""

# Progress goes to standard error. A closed or broken stderr never fails the script.
log() { printf 'fanout: %s\n' "$*" >&2 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Output and exit — every exit goes through finish(), which prints the JSON once.
# ---------------------------------------------------------------------------
instances_json() { # the "instances" array of the output
  local i
  {
    for i in "${!I_NAME[@]}"; do
      jq -cn --arg n "${I_NAME[i]}" --arg u "${I_UUID[i]}" --arg s "${I_SERIAL[i]}" --arg st "${I_STATUS[i]}" \
        '{name: $n, uuid: (if $u == "" then null else $u end),
          serial: (if $s == "" or $st != "ONLINE" then null else $s end), status: $st}'
    done
  } | jq -cs '.'
}

# The run record: the four output keys plus "stop_verified".
record_json() { # [run-id]
  local i
  {
    for i in "${!I_NAME[@]}"; do
      if [ -n "${1:-}" ] && [ "${E_RUN[i]:-}" != "$1" ]; then continue; fi
      jq -cn --arg n "${I_NAME[i]}" --arg u "${I_UUID[i]}" --arg s "${I_SERIAL[i]}" --arg st "${I_STATUS[i]}" \
        --arg v "${I_VSTOP[i]:-0}" \
        '{name: $n, uuid: (if $u == "" then null else $u end),
          serial: (if $s == "" or $st != "ONLINE" then null else $s end), status: $st,
          stop_verified: ($v == "1")}'
    done
  } | jq -cs '.'
}

json_escape() { # used only when jq is missing: drop control characters, escape \ and "
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\037')"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Prints the JSON object. Returns 1 when standard output cannot be written.
emit() { # error-message (empty for success)
  local err="${1:-}" inst json
  [ "$OUTPUT_DONE" -eq 0 ] || return 0
  OUTPUT_DONE=1
  if [ "$HAVE_JQ" -eq 0 ]; then
    if [ "$CMD" = "start" ]; then
      json="{\"run_id\": null, \"adb\": null, \"instances\": [], \"error\": \"$(json_escape "$err")\"}"
    else
      json="{\"run_id\": null, \"instances\": [], \"error\": \"$(json_escape "$err")\"}"
    fi
  else
    inst="$(instances_json)" || inst='[]'
    # "adb" is in the output of start only: the adb the script used, or null.
    json="$(jq -cn --arg run "$RUN_ID" --argjson inst "$inst" --arg err "$err" \
      --arg cmd "$CMD" --arg adb "$ADB_BIN" \
      '{run_id: (if $run == "" then null else $run end)}
       + (if $cmd == "start" then {adb: (if $adb == "" then null else $adb end)} else {} end)
       + {instances: $inst}
       + (if $err == "" then {} else {error: $err} end)')" ||
      json='{"run_id": null, "instances": [], "error": "internal error while printing the result"}'
    if [ "$CMD" = "start" ] && [[ "$json" != *'"adb"'* ]]; then
      json='{"run_id": null, "adb": null, "instances": [], "error": "internal error while printing the result"}'
    fi
  fi
  printf '%s\n' "$json" 2>/dev/null
}

# A start call that failed may still have created an instance that gmsaas
# lists only later: say so, so that the final "stop --run" is not skipped.
warn_unlisted_start_failures() {
  local i
  [ "$CMD" = "start" ] && [ -n "$RUN_ID" ] || return 0
  for i in "${!I_NAME[@]}"; do
    if [ "${I_STATUS[i]}" = "START_FAILED" ] && [ -z "${I_UUID[i]}" ]; then
      log "warning: ${I_NAME[i]}: its start call failed and gmsaas did not list it, but the instance may still appear: run 'fanout.sh stop --run $RUN_ID' when you are done"
    fi
  done
}

finish() { # exit-code [error-message]
  local code="$1" msg="${2:-}"
  if [ "$code" -ne 0 ] && [ -z "$msg" ]; then msg="failed with exit code $code"; fi
  [ -z "$msg" ] || log "error: $msg"
  warn_unlisted_start_failures
  START_ACTIVE=0
  emit "$msg" || true
  exit "$code"
}

# finish() for exit 2 also clears the instance list: nothing was started.
config_error() {
  I_NAME=() I_UUID=() I_SERIAL=() I_STATUS=() I_VSTOP=() E_RUN=()
  finish 2 "$1"
}

# ---------------------------------------------------------------------------
# Waiting and signals
# ---------------------------------------------------------------------------
kill_sleep() {
  if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null || true; SLEEP_PID=""; fi
}

# Interruptible wait: a plain foreground sleep would delay the trap until it ends.
nap() {
  local n="$1"
  [ "$n" -gt 0 ] || return 0
  sleep "$n" >/dev/null 2>&1 &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  SLEEP_PID=""
}

# Called by the handlers while a gmsaas call may be running in the background.
# An in-flight "instances start" is waited for (bounded): the instance it creates
# must be known so it can be stopped. Any other call is killed.
settle_gm_call() {
  local k u
  if [ -n "$ADB_PID" ]; then kill "$ADB_PID" 2>/dev/null || true; ADB_PID=""; fi
  if [ -n "$ADB_WD" ]; then kill "$ADB_WD" 2>/dev/null || true; ADB_WD=""; fi
  if [ "$GM_KIND" = "instances start" ] && [ -n "$GM_INDEX" ]; then
    # A signal between the launch and "GM_PID=$!" leaves GM_PID empty: take the job.
    if [ -z "$GM_PID" ] && [ -z "$(jq -r '.instance.uuid // empty' "$WORK_DIR/gm.out" 2>/dev/null)" ]; then
      GM_PID="$(jobs -p | tail -n 1)"
    fi
    if [ -n "$GM_PID" ]; then
      log "waiting for the start call in flight to return (at most $START_CALL_WAIT s)"
      for ((k = 0; k < START_CALL_WAIT; k++)); do
        kill -0 "$GM_PID" 2>/dev/null || break
        nap 1
      done
      kill -KILL "$GM_PID" 2>/dev/null || true
      wait "$GM_PID" 2>/dev/null || true
    fi
    u="$(jq -r '.instance.uuid // empty' "$WORK_DIR/gm.out" 2>/dev/null)" || u=""
    if [ -z "${I_UUID[GM_INDEX]:-}" ]; then
      if [ -n "$u" ]; then
        I_UUID[GM_INDEX]="$u"
        log "${I_NAME[GM_INDEX]}: started ($u)"
      elif [ "${I_STATUS[GM_INDEX]:-}" = "STARTING" ]; then
        # The cut start call gave no UUID: it may still have created an instance.
        I_STATUS[GM_INDEX]="START_FAILED"
        log "${I_NAME[GM_INDEX]}: the start call was cut and gave no instance UUID"
      fi
    fi
  elif [ -n "$GM_PID" ]; then
    kill -KILL "$GM_PID" 2>/dev/null || true
    wait "$GM_PID" 2>/dev/null || true
  fi
  stop_watchdog "$GM_WD"
  GM_PID="" GM_KIND="" GM_INDEX="" GM_WD=""
}

# Tears the whole run down, then exits with CODE when every instance is verified
# gone, or 6 with the real number still running. Signals are ignored meanwhile.
teardown_and_finish() { # code reason
  trap '' INT TERM HUP
  if teardown_run_all; then
    finish "$1" "$2; $(teardown_summary)"
  fi
  finish 6 "$2; $(not_verified_message)"
}

# The one wording of an incomplete stop (exit 6), for start and stop.
not_verified_message() {
  local again="fanout.sh stop --run $RUN_ID"
  [ -n "$RUN_ID" ] || again="fanout.sh stop --all-mine"
  printf '%s instance(s) not verified stopped: run %s again, then check https://cloud.geny.io/instances' \
    "${#STOP_REMAINING[@]}" "'$again'"
}

# stop without a single successful list: exit 6 whatever the stop calls did.
# The lookup by name never ran on a successful list: exit 6, saying what was done.
no_list_message() {
  local again="fanout.sh stop --run $RUN_ID" sent="no stop call was sent"
  [ -n "$RUN_ID" ] || again="fanout.sh stop --all-mine"
  [ "$STOP_CALLS_SENT" -eq 0 ] || sent="stop calls were sent from the run records"
  printf "the instances could not be listed for the lookup by name (names not swept): %s, %s instance(s) not verified stopped, and no instance could be looked up by name: run '%s' again, then check https://cloud.geny.io/instances" \
    "$sent" "${#STOP_REMAINING[@]}" "$again"
}

# What a verified teardown of the run proves.
teardown_summary() {
  local i blind=0
  for i in "${!I_NAME[@]}"; do
    if [ "${I_STATUS[i]}" = "START_FAILED" ] && [ -z "${I_UUID[i]}" ]; then blind=$((blind + 1)); fi
  done
  if [ "$blind" -eq 0 ]; then
    printf 'every instance of the run was stopped'
  else
    printf "every instance of the run that gmsaas returned or listed was stopped; %d failed start call(s) may still have created an instance: run 'fanout.sh stop --run %s' when you are done" \
      "$blind" "$RUN_ID"
  fi
}

on_signal() { # signal-name exit-code
  local sig="$1" code="$2"
  set +e
  kill_sleep
  if [ "$START_ACTIVE" -eq 1 ]; then
    trap '' INT TERM HUP
    settle_gm_call
    log "received SIG$sig: stopping every instance of run $RUN_ID"
    teardown_and_finish "$code" "interrupted by SIG$sig"
  fi
  trap '' INT TERM HUP
  settle_gm_call
  # stop: report the last known live state, not the recorded one.
  [ "$CMD" != "stop" ] || refresh_from_live
  finish "$code" "interrupted by SIG$sig"
}

on_exit() {
  local rc=$? orig
  trap '' INT TERM HUP
  set +e
  kill_sleep
  settle_gm_call
  if [ "$START_ACTIVE" -eq 1 ]; then
    orig=$rc
    if [ "$STARTED_ANY" -eq 1 ]; then
      # A crash after the first start call: stop everything of the run.
      log "internal error (exit $orig): stopping every instance of run $RUN_ID"
      warn_unlisted_start_failures
      if teardown_run_all; then
        rc=5
        emit "internal error (exit code $orig); $(teardown_summary)"
      else
        rc=6
        emit "internal error (exit code $orig); $(not_verified_message)"
      fi
    else
      rc=2
      log "error: internal error (exit $orig) before any instance was started"
      emit "internal error (exit code $orig) before any instance was started"
    fi
    START_ACTIVE=0
  elif [ "$OUTPUT_DONE" -eq 0 ]; then
    # stop cannot claim a verified teardown after an internal error.
    if [ "$CMD" = "stop" ]; then rc=6; else rc=2; fi
    log "error: internal error"
    emit "internal error"
  fi
  [ -z "$PID_FILE" ] || rm -f "$PID_FILE"
  [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
  exit "$rc"
}

trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  fanout.sh start [--count N] [--recipe <uuid|name>] [--prefix <p>]
                  [--max-run-duration <minutes>] [--base-port <port>] [--min <M>]
  fanout.sh status [--run <run-id>]
  fanout.sh stop   [--run <run-id> | --all-mine]
  fanout.sh --help

Starts N Genymotion SaaS instances in parallel, waits until each is ONLINE,
connects ADB on distinct ports, checks every serial with "adb devices", and
prints one JSON object on standard output. Progress and errors go to standard
error. Run it from the project directory: it reads ./.genymotion.json and
writes its state under ./.genymotion/runs/.

Requirements: Bash 4.4 or later, jq, gmsaas (authenticated). adb: the one of
the Android SDK configured in gmsaas (<android-sdk-path>/platform-tools/adb),
else the one in PATH.

Commands:
  start               Start N instances (default 1) and connect ADB. Prints its run id on
                      standard error before the first instance is started.
  status              Live state and serial of each instance of a run (default: the most recent run).
  stop                Stop every instance of a run (default: the most recent run), then verify.
                      A start still running for that run tears itself down (exit 5).
                      With --run and no record of the run here, the instances are found by
                      their names (<any prefix>-<run-id>-<index>) in the account.
  stop --all-mine     Stop every run recorded here with the configured prefix, and every running
                      instance named <prefix>-<run-id>-<index>, then verify. Other prefixes are left alone.

Settings (flag > environment variable > .genymotion.json key > default):
  --recipe            GENYMOTION_SAAS_RECIPE / saasRecipe (default: none, required). A recipe UUID or a name from "recipes".
  --prefix            GENYMOTION_INSTANCE_PREFIX / instancePrefix (default: ${DEFAULT_PREFIX}). Letters, digits, - and _; 32 characters at most.
  --max-run-duration  GENYMOTION_MAX_RUN_DURATION / maxRunDuration (default: ${DEFAULT_DURATION} minutes). Minutes, 1 to 28800.
  --base-port         GENYMOTION_ADB_BASE_PORT / adbBasePort (default: ${DEFAULT_BASE_PORT}). 1024 to 65535.
  --count             Number of instances to start (default: 1). At most the cap below.
  --min               Smallest number of usable instances that makes the run worth keeping (default: 1).
  (no flag)           GENYMOTION_MAX_INSTANCES / maxInstances (default: ${DEFAULT_MAX_INSTANCES}). Cap on --count.
  (no flag)           GENYMOTION_PLATFORM / platform (default: none). "start" refuses "desktop".
  (no flag)           GENYMOTION_POLL_INTERVAL (default: ${DEFAULT_POLL_INTERVAL} seconds). Between two boot polls, ${BOOT_POLLS} polls at most.
  (no flag)           GENYMOTION_STOP_POLL_INTERVAL (default: ${DEFAULT_STOP_POLL_INTERVAL} seconds). Between two stop checks, ${STOP_POLLS} checks at most.
  (no flag)           GENYMOTION_CALL_TIMEOUT (default: ${GMSAAS_CALL_LIMIT} seconds, and ${GMSAAS_SLOW_CALL_LIMIT} for instances stop and instances adbconnect).
                      Time limit of every gmsaas call, 1 to 3600 seconds. For tests.
  An empty environment variable, or an empty string in .genymotion.json, counts as not set.
  The API token is read by gmsaas itself.

Output (standard output, one JSON object):
  {"run_id": "...", "adb": "<path>" (start only), "instances": [{"name", "uuid", "serial", "status"}],
   "error": "..." (only when the exit code is not 0)}
  adb: the adb start used (null when it did not get that far). Use the same adb for your own commands.
  status: ONLINE, START_FAILED, BOOT_FAILED, TIMEOUT, ADB_FAILED, STOPPED (stopped and verified: not
          listed, and gmsaas instances get reports it deleted or not found), UNVERIFIED (status and stop
          only: not listed, and gmsaas could not say whether it still exists), or a live gmsaas state
          (status and stop only; gmsaas STOPPED is shown as STOPPING).

Exit codes:
  0    success: start has at least --min usable instances; stop verified, nothing is running; status printed
  1    partial: start: some instances came up, but fewer than --min; everything was stopped
  2    configuration: bad flag, missing or invalid setting, count above the cap, jq / adb / gmsaas not found,
       a project directory that cannot be written, (status) a run file that cannot be read, or
       (stop --run, status --run) a run id with no record here and no instance in the account;
       nothing was started
  3    gmsaas failed: not authenticated, Android SDK path not set, API or network error, or no instance
       could be created; also for status, and for stop without a run record, when the instances cannot be listed
  4    timeout: start: no instance usable and at least one still starting after the last poll;
       everything was stopped
  5    failed: start: no instance usable (boot or ADB failures), the stop of a failed instance could not
       be verified at first, a stop was requested for this run, the result could not be printed, or an
       internal error; everything was stopped, healthy instances included
  6    stop incomplete: at least one instance is not verified stopped, or the instances could not be listed; run stop again, then check
       https://cloud.geny.io/instances
  129, 130, 143  interrupted (hang-up, Ctrl-C, termination): start stopped everything it had started
  A non-zero exit code from start means that every instance it created was stopped, except 6.
  Always run "fanout.sh stop --run <run-id>" at the end: it also stops an instance whose start call
  failed and that was listed too late.

Examples:
  RESULT="\$(fanout.sh start --count 3 --recipe phone)"
  RUN_ID="\$(jq -r '.run_id' <<<"\$RESULT")"
  jq -r '.instances[] | select(.status == "ONLINE") | .serial' <<<"\$RESULT"
  fanout.sh stop --run "\$RUN_ID"
  GENYMOTION_PLATFORM=saas fanout.sh start --count 2 --min 2
EOF
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
require_tools() {
  if ! command -v jq >/dev/null 2>&1; then
    finish 2 "jq not found: install it with your package manager (apt install jq, dnf install jq, brew install jq)"
  fi
  HAVE_JQ=1
  if ! command -v gmsaas >/dev/null 2>&1; then
    config_error "gmsaas not found: install it with 'pip install gmsaas', then authenticate (see references/setup-gmsaas.md)"
  fi
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fanout.XXXXXX" 2>/dev/null)" ||
    config_error "cannot create a temporary directory in ${TMPDIR:-/tmp}: set TMPDIR to a writable directory"
}

# adb: the one of the Android SDK configured in gmsaas, else the one in PATH.
resolve_adb() {
  local sdk="" cand
  gm config get android-sdk-path
  if [ "$GM_RC" -eq 0 ]; then
    sdk="$(jq -r '.configuration["android-sdk-path"] // empty' <<<"$GM_OUT")" || sdk=""
  else
    log "cannot read the Android SDK path from gmsaas ($GM_ERR_MSG)"
  fi
  # A leading "~" in the configured path stands for the home directory.
  case "$sdk" in
    \~) sdk="${HOME:-}" ;;
    \~/*) sdk="${HOME:-}/${sdk:2}" ;;
  esac
  cand="$sdk/platform-tools/adb"
  if [ -n "$sdk" ] && [ -f "$cand" ] && [ -x "$cand" ]; then
    ADB_BIN="$cand"
    log "using adb of the Android SDK configured in gmsaas: $ADB_BIN"
    return 0
  fi
  if ADB_BIN="$(command -v adb 2>/dev/null)"; then
    if [ -n "$sdk" ]; then log "no adb in $sdk/platform-tools: using adb from PATH: $ADB_BIN"; else log "no Android SDK path in gmsaas: using adb from PATH: $ADB_BIN"; fi
    return 0
  fi
  config_error "adb not found: set the Android SDK path with 'gmsaas config set android-sdk-path <android-sdk>', or add <android-sdk>/platform-tools to PATH"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONFIG_CHECKED=0
check_config_file() {
  [ "$CONFIG_CHECKED" -eq 0 ] || return 0
  CONFIG_CHECKED=1
  [ -e "$CONFIG_FILE" ] || return 0
  if ! jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    config_error ".genymotion.json is not a valid JSON object: fix or remove $CONFIG_FILE"
  fi
}

cfg_get() { # key -> value on stdout (empty when unset)
  [ -e "$CONFIG_FILE" ] || return 0
  jq -r --arg k "$1" '.[$k]
    | if . == null then empty
      elif type == "string" or type == "number" then tostring
      else "<invalid \(type)>" end' "$CONFIG_FILE"
}

# resolve FLAG-VALUE ENV-NAME FILE-KEY DEFAULT -> sets RV (value) and RS (source)
resolve() {
  local flag="$1" env_name="$2" key="$3" def="$4" file_val
  if [ -n "$flag" ]; then RV="$flag"; RS="flag"; return 0; fi
  if [ -n "$env_name" ] && [ -n "${!env_name:-}" ]; then RV="${!env_name}"; RS="$env_name"; return 0; fi
  if [ -n "$key" ]; then
    file_val="$(cfg_get "$key")"
    if [ -n "$file_val" ]; then RV="$file_val"; RS=".genymotion.json $key"; return 0; fi
  fi
  RV="$def"; RS="default"
}

# in_range VALUE LOW HIGH: a plain decimal integer (no sign, no leading zero) within [LOW, HIGH].
in_range() {
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

configuration_message() {
  cat >&2 2>/dev/null <<EOF || true
Genymotion is not configured for unattended use: $1 is not set.
Set it in the environment, for example:
  export GENYMOTION_PLATFORM=saas
  export GENYMOTION_SAAS_RECIPE=<recipe_uuid>     # find one with: gmsaas recipes list
or in .genymotion.json at the repository root.
See references/configuration.md for every setting.
EOF
}

# Tests only: one time limit, in seconds, for every gmsaas call.
resolve_call_limit() {
  if [ -n "${GENYMOTION_CALL_TIMEOUT:-}" ]; then
    in_range "$GENYMOTION_CALL_TIMEOUT" 1 3600 || config_error "GENYMOTION_CALL_TIMEOUT must be a whole number of seconds from 1 to 3600 (got '$GENYMOTION_CALL_TIMEOUT')"
    GM_LIMIT_OVERRIDE="$GENYMOTION_CALL_TIMEOUT"
  fi
}

resolve_intervals() {
  resolve "" GENYMOTION_POLL_INTERVAL "" "$DEFAULT_POLL_INTERVAL"
  in_range "$RV" 0 86400 || config_error "GENYMOTION_POLL_INTERVAL must be a whole number of seconds from 0 to 86400 (got '$RV')"
  POLL_INTERVAL="$RV"
  resolve "" GENYMOTION_STOP_POLL_INTERVAL "" "$DEFAULT_STOP_POLL_INTERVAL"
  in_range "$RV" 0 86400 || config_error "GENYMOTION_STOP_POLL_INTERVAL must be a whole number of seconds from 0 to 86400 (got '$RV')"
  STOP_POLL_INTERVAL="$RV"
}

resolve_prefix() { # flag-value
  resolve "$1" GENYMOTION_INSTANCE_PREFIX instancePrefix "$DEFAULT_PREFIX"
  [[ "$RV" =~ $PREFIX_RE ]] ||
    config_error "invalid instance prefix '$RV' (from $RS): use letters, digits, - and _, start with a letter or digit, 32 characters at most"
  PREFIX="$RV"
}

resolve_start_settings() {
  local platform recipe_src desktop names
  check_config_file

  # Platform: env > file > implied by which of recipe / desktop device is set.
  resolve "" GENYMOTION_PLATFORM platform ""
  platform="$RV"
  if [ -n "$platform" ] && [ "$platform" != "saas" ] && [ "$platform" != "desktop" ]; then
    config_error "invalid platform '$platform' (from $RS): use saas or desktop"
  fi
  resolve "$F_RECIPE" GENYMOTION_SAAS_RECIPE saasRecipe ""
  RECIPE="$RV" recipe_src="$RS"
  resolve "" GENYMOTION_DESKTOP_DEVICE desktopDevice ""
  desktop="$RV"
  if [ -z "$platform" ] && [ -z "$RECIPE" ] && [ -n "$desktop" ]; then platform="desktop"; fi
  if [ "$platform" = "desktop" ]; then
    config_error "the platform resolves to desktop, and fanout.sh only starts Genymotion SaaS instances. For an explicit SaaS request, set GENYMOTION_PLATFORM=saas on the call."
  fi

  # Recipe: a UUID, or a name from "recipes".
  if [ -z "$RECIPE" ]; then
    configuration_message GENYMOTION_SAAS_RECIPE
    config_error "Genymotion is not configured for unattended use: GENYMOTION_SAAS_RECIPE is not set."
  fi
  if ! [[ "$RECIPE" =~ $UUID_RE ]]; then
    local looked_up=""
    if [ -e "$CONFIG_FILE" ]; then
      looked_up="$(jq -r --arg n "$RECIPE" '(.recipes // {}) | if type == "object" then (.[$n] // empty | tostring) else empty end' "$CONFIG_FILE")"
    fi
    if [ -z "$looked_up" ]; then
      names=""
      if [ -e "$CONFIG_FILE" ]; then
        names="$(jq -r '(.recipes // {}) | if type == "object" then keys | join(", ") else "" end' "$CONFIG_FILE")"
      fi
      config_error "unknown recipe name '$RECIPE' (from $recipe_src): it is not a UUID and not a key of \"recipes\" in .genymotion.json. Known names: ${names:-none}"
    fi
    [[ "$looked_up" =~ $UUID_RE ]] ||
      config_error "recipe '$RECIPE' maps to '$looked_up' in .genymotion.json, which is not a recipe UUID"
    log "recipe '$RECIPE' resolves to $looked_up"
    RECIPE="$looked_up"
  fi

  # Cap, count, min.
  resolve "" GENYMOTION_MAX_INSTANCES maxInstances "$DEFAULT_MAX_INSTANCES"
  in_range "$RV" 1 999999 || config_error "invalid maximum number of instances '$RV' (from $RS): use a whole number, 1 or more"
  MAX_INSTANCES="$RV"
  local cap_src="$RS"
  COUNT="${F_COUNT:-1}"
  in_range "$COUNT" 1 999999 || config_error "invalid --count '$COUNT': use a whole number, 1 or more"
  if [ "$COUNT" -gt "$MAX_INSTANCES" ]; then
    config_error "--count $COUNT is above the cap of $MAX_INSTANCES instances (from $cap_src). Nothing was started. To raise the cap, set GENYMOTION_MAX_INSTANCES or \"maxInstances\" in .genymotion.json."
  fi
  MIN="${F_MIN:-1}"
  in_range "$MIN" 1 999999 || config_error "invalid --min '$MIN': use a whole number from 1 to --count ($COUNT)"
  [ "$MIN" -le "$COUNT" ] || config_error "--min $MIN is above --count $COUNT"

  # Duration in minutes; 0 would mean "no limit" for gmsaas, so it is refused.
  resolve "$F_DURATION" GENYMOTION_MAX_RUN_DURATION maxRunDuration "$DEFAULT_DURATION"
  in_range "$RV" 1 28800 ||
    config_error "invalid max run duration '$RV' (from $RS): use a whole number of minutes from 1 to 28800 (0 would mean no limit and is refused)"
  DURATION="$RV"

  resolve_prefix "$F_PREFIX"

  resolve "$F_BASE_PORT" GENYMOTION_ADB_BASE_PORT adbBasePort "$DEFAULT_BASE_PORT"
  in_range "$RV" 1024 65535 || config_error "invalid ADB base port '$RV' (from $RS): use a port from 1024 to 65535"
  BASE_PORT="$RV"
  [ $((BASE_PORT + COUNT - 1)) -le 65535 ] ||
    config_error "ADB base port $BASE_PORT with $COUNT instances goes past port 65535: use a lower base port"
}

# ---------------------------------------------------------------------------
# gmsaas helpers (always --format compactjson; never -v)
# ---------------------------------------------------------------------------
# The call runs in the background and is waited for, so a signal reaches the
# trap at once instead of after the call (which can take a minute).
# Each call has a time limit (watchdog): on expiry the call is killed and counts
# as a failed call, "gmsaas <command> did not answer within N s".
# GM_KIND stays set after the call: start_instances clears it once the UUID of a
# start call is stored, so a signal handler can still read it from the output.
gm() {
  local out="$WORK_DIR/gm.out" errf="$WORK_DIR/gm.err" flag="$WORK_DIR/gm.timeout" limit
  GM_RC=0 GM_ERR_MSG="" GM_OUT=""
  GM_KIND="${1:-} ${2:-}"
  case "$GM_KIND" in
    "instances stop"|"instances adbconnect") limit="$GMSAAS_SLOW_CALL_LIMIT" ;;
    *) limit="$GMSAAS_CALL_LIMIT" ;;
  esac
  [ -z "$GM_LIMIT_OVERRIDE" ] || limit="$GM_LIMIT_OVERRIDE"
  rm -f "$flag" "$out" "$errf"
  gmsaas --format compactjson "$@" >"$out" 2>"$errf" </dev/null &
  GM_PID=$!
  start_watchdog "$GM_PID" "$limit" "$flag"
  GM_WD="$WD_PID"
  wait "$GM_PID" || GM_RC=$?
  GM_PID=""
  stop_watchdog "$GM_WD"
  GM_WD=""
  GM_OUT="$(cat "$out" 2>/dev/null)" || GM_OUT=""
  if [ -e "$flag" ]; then
    GM_RC=124
    GM_ERR_MSG="gmsaas $GM_KIND did not answer within $limit s"
    return 0
  fi
  if [ "$GM_RC" -eq 0 ] && ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$GM_OUT"; then
    GM_RC=1
    GM_ERR_MSG="unexpected output from gmsaas (not a JSON object)"
    return 0
  fi
  if [ "$GM_RC" -ne 0 ]; then
    GM_ERR_MSG="$(jq -r '.error.message // empty' "$errf" 2>/dev/null)" || GM_ERR_MSG=""
    if [ -z "$GM_ERR_MSG" ]; then
      # Not JSON (a usage error is plain text): keep its last non-empty line.
      GM_ERR_MSG="$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -n 1 | head -c 300)" || GM_ERR_MSG=""
    fi
    [ -n "$GM_ERR_MSG" ] || GM_ERR_MSG="gmsaas exited with code $GM_RC"
    GM_ERR_MSG="$GM_ERR_MSG (gmsaas exit code $GM_RC)"
  fi
}

# One "instances list" call. Fills LIVE_* maps. Returns 1 when the call failed.
live_list() {
  local u n s a
  gm instances list
  if [ "$GM_RC" -eq 0 ] && ! jq -e '.instances | type == "array"' >/dev/null 2>&1 <<<"$GM_OUT"; then
    GM_RC=1 GM_ERR_MSG="unexpected output from gmsaas instances list"
  fi
  if [ "$GM_RC" -ne 0 ]; then LIVE_VALID=0; return 1; fi
  LIVE_STATE=() LIVE_SERIAL=() LIVE_BY_NAME=()
  while IFS=$'\x1f' read -r u n s a _; do
    [ -n "$u" ] || continue
    LIVE_STATE["$u"]="$s" LIVE_SERIAL["$u"]="$a"
    [ -z "$n" ] || LIVE_BY_NAME["$n"]="$u"
  done < <(jq -r '.instances[] | [(.uuid // ""), (.name // ""), (.state // ""), (.adb_serial // ""), "."] | map(tostring) | join("\u001f")' <<<"$GM_OUT")
  LIVE_VALID=1
}

# Listed and not yet DELETED, according to the last live_list.
is_alive() {
  [ -n "$1" ] && [ -n "${LIVE_STATE[$1]+x}" ] && [ "${LIVE_STATE[$1]}" != "DELETED" ]
}

is_failure_status() { [[ "$FAILURE_STATUSES" == *" $1 "* ]]; }

stop_call() { # uuid
  STOP_CALLS_SENT=$((STOP_CALLS_SENT + 1))
  gm instances stop --no-wait "$1"
  if [ "$GM_RC" -eq 0 ]; then log "stopping $1"; else log "stop $1: $GM_ERR_MSG"; fi
}

# Live state as this script reports it: gmsaas "STOPPED" (still listed) is shown
# as STOPPING, because STOPPED here always means verified gone.
shown_state() { if [ "$1" = "STOPPED" ]; then printf 'STOPPING'; else printf '%s' "$1"; fi; }

# Existence of one instance, asked with "instances get". Sets GET_STATE and returns:
#   0  it exists (GET_STATE: its gmsaas state)
#   1  it no longer exists: an API error 404 with a gmsaas (non-HTML) body, or
#      the state DELETED
#   2  unknown: any other failure. gmsaas gives exit 4 for every HTTP status, and
#      replaces an HTML body (proxy, maintenance page) with "<HTML content":
#      such a 404 proves nothing.
instance_exists() { # uuid
  local not_found='^API returns unexpected code: 404\. Error: '
  GET_STATE=""
  gm instances get "$1"
  if [ "$GM_RC" -eq 0 ]; then
    GET_STATE="$(jq -r '.instance.state // empty' <<<"$GM_OUT")" || GET_STATE=""
    if [ "$GET_STATE" = "DELETED" ]; then return 1; fi
    [ -n "$GET_STATE" ] || return 2
    return 0
  fi
  if [ "$GM_RC" -eq 4 ] && [[ "$GM_ERR_MSG" =~ $not_found ]] && [[ "$GM_ERR_MSG" != *"<HTML content"* ]]; then
    return 1
  fi
  return 2
}

# stop_and_verify UUID...: stop every target, then verify.
# - A stop call goes to every target, except one its run record already gives as
#   verified stopped (KNOWN_GONE). Its outcome proves nothing.
# - A target is verified stopped only when, in the same round, a successful
#   "instances list" does not show it (or shows it DELETED) AND "instances get"
#   says it no longer exists (instance_exists returns 1). A round whose list
#   fails verifies nothing.
# - A stop is sent again to a target that still exists and is not on its way
#   out, and to a target whose last stop call failed.
# Each round: 1 list, plus 1 get for each target the list does not show, plus a
# stop for the targets above. STOP_POLLS rounds at most, STOP_POLL_INTERVAL
# seconds apart. Sets STOP_GONE (verified), STOP_OBS (last state seen: a gmsaas
# state, or UNVERIFIED) and STOP_REMAINING (not verified).
# Returns 0 when every target is verified stopped.
stop_and_verify() {
  local u p rc
  local -a targets=() remaining=() still=()
  declare -A stop_ok=()
  for u in "$@"; do [ -z "$u" ] || targets+=("$u"); done
  STOP_REMAINING=() STOP_TARGETS=() STOP_GONE=() STOP_OBS=()
  [ "${#targets[@]}" -gt 0 ] || return 0
  for u in "${targets[@]}"; do STOP_TARGETS["$u"]=1; done
  for u in "${targets[@]}"; do
    if [ -n "${KNOWN_GONE[$u]+x}" ]; then
      STOP_GONE["$u"]=1
      continue
    fi
    stop_call "$u"
    if [ "$GM_RC" -eq 0 ]; then stop_ok["$u"]=1; fi
    remaining+=("$u")
  done
  for ((p = 1; p <= STOP_POLLS; p++)); do
    [ "${#remaining[@]}" -gt 0 ] || return 0
    if [ "$p" -gt 1 ]; then nap "$STOP_POLL_INTERVAL"; fi
    if ! live_list; then
      log "stop check $p/$STOP_POLLS: cannot list instances ($GM_ERR_MSG): nothing verified in this round"
      for u in "${remaining[@]}"; do
        if [ -z "${stop_ok[$u]+x}" ]; then
          stop_call "$u"
          if [ "$GM_RC" -eq 0 ]; then stop_ok["$u"]=1; fi
        fi
      done
      continue
    fi
    still=()
    for u in "${remaining[@]}"; do
      if is_alive "$u"; then
        STOP_OBS["$u"]="${LIVE_STATE[$u]}"
        still+=("$u")
        if [[ "$LEAVING_STATES" != *" ${LIVE_STATE[$u]} "* ]] || [ -z "${stop_ok[$u]+x}" ]; then
          log "$u is still ${LIVE_STATE[$u]}: stopping it again"
          stop_call "$u"
          if [ "$GM_RC" -eq 0 ]; then stop_ok["$u"]=1; fi
        fi
        continue
      fi
      # Not listed in this round: gmsaas must also say it no longer exists.
      rc=0
      instance_exists "$u" || rc=$?
      if [ "$rc" -eq 1 ]; then
        log "$u: not listed, and gmsaas instances get says it no longer exists"
        STOP_GONE["$u"]=1
        continue
      fi
      still+=("$u")
      if [ "$rc" -eq 0 ]; then
        STOP_OBS["$u"]="$GET_STATE"
        if [[ "$LEAVING_STATES" != *" $GET_STATE "* ]] || [ -z "${stop_ok[$u]+x}" ]; then
          log "$u is not listed but still $GET_STATE: stopping it again"
          stop_call "$u"
          if [ "$GM_RC" -eq 0 ]; then stop_ok["$u"]=1; fi
        fi
      else
        STOP_OBS["$u"]="UNVERIFIED"
        log "$u: not listed, and gmsaas cannot tell whether it still exists ($GM_ERR_MSG)"
        if [ -z "${stop_ok[$u]+x}" ]; then
          stop_call "$u"
          if [ "$GM_RC" -eq 0 ]; then stop_ok["$u"]=1; fi
        fi
      fi
    done
    remaining=("${still[@]}")
  done
  [ "${#remaining[@]}" -gt 0 ] || return 0
  STOP_REMAINING=("${remaining[@]}")
  log "${#STOP_REMAINING[@]} instance(s) not verified stopped after $STOP_POLLS checks: ${STOP_REMAINING[*]}"
  return 1
}

# After stop_and_verify: each target verified gone becomes STOPPED (unless it
# carries a failure status) and is recorded as stop_verified; any other target
# takes the last state seen (UNVERIFIED when gmsaas could not tell).
mark_stopped() {
  local i u
  for i in "${!I_NAME[@]}"; do
    u="${I_UUID[i]}"
    [ -n "$u" ] && [ -n "${STOP_TARGETS[$u]+x}" ] || continue
    if [ -n "${STOP_GONE[$u]+x}" ]; then
      I_VSTOP[i]=1
      is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="STOPPED"
    elif [ -n "${STOP_OBS[$u]+x}" ]; then
      I_STATUS[i]="$(shown_state "${STOP_OBS[$u]}")"
    elif ! is_failure_status "${I_STATUS[i]}"; then
      I_STATUS[i]="UNVERIFIED"   # no round could observe it
    fi
  done
}

# Interrupted stop: each entry takes its last known live state.
refresh_from_live() {
  local i u
  [ "$LIVE_VALID" -eq 1 ] || return 0
  for i in "${!I_NAME[@]}"; do
    u="${I_UUID[i]}"
    [ -n "$u" ] || continue
    if is_alive "$u"; then
      I_STATUS[i]="$(shown_state "${LIVE_STATE[$u]}")"
    elif [ -n "${STOP_GONE[$u]+x}" ]; then
      I_VSTOP[i]=1
      is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="STOPPED"
    elif [ "${STOP_OBS[$u]:-}" = "UNVERIFIED" ]; then
      is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="UNVERIFIED"
    else
      resolve_unlisted "$i"
    fi
  done
}

# Status of an entry the last successful list does not show: STOPPED only when
# verified (the record says so, or "instances get" reports it no longer exists:
# with the list, the same proof as in stop); its gmsaas state when it still
# exists; UNVERIFIED when gmsaas cannot tell. A failure status is kept when the
# instance is gone or unknown. Read-only: never a stop call.
resolve_unlisted() { # index
  local i="$1" u="${I_UUID[$1]}" rc=0
  if [ "${I_VSTOP[i]:-0}" = "1" ]; then
    is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="STOPPED"
    return 0
  fi
  instance_exists "$u" || rc=$?
  case "$rc" in
    0) I_STATUS[i]="$(shown_state "$GET_STATE")" ;;
    1) is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="STOPPED" ;;
    *) is_failure_status "${I_STATUS[i]}" || I_STATUS[i]="UNVERIFIED" ;;
  esac
}

# An entry without a UUID (start killed during its start call, or a failed start
# call that still created the instance) takes the UUID of the live instance with
# exactly its name, from the last live_list. Returns 0 when one was adopted.
adopt_by_name() {
  local i n adopted=1
  for i in "${!I_NAME[@]}"; do
    n="${I_NAME[i]}"
    if [ -z "${I_UUID[i]}" ] && [ -n "$n" ] && [ -n "${LIVE_BY_NAME[$n]+x}" ]; then
      I_UUID[i]="${LIVE_BY_NAME[$n]}"
      log "$n: found in the instance list by its name (${I_UUID[i]})"
      adopted=0
    fi
  done
  return "$adopted"
}

has_uuid() { # uuid -> 0 when an entry carries it
  local i
  for i in "${!I_UUID[@]}"; do [ "${I_UUID[i]}" != "$1" ] || return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Run state files
# ---------------------------------------------------------------------------
state_file() { printf '%s/%s.json' "$RUNS_DIR" "$1"; }
stop_marker() { printf '%s/%s.stop' "$RUNS_DIR" "$1"; }
pid_file() { printf '%s/%s.pid' "$RUNS_DIR" "$1"; }

# Atomic write: temporary file in the same directory (never *.json), then mv.
# Never replaces a file with empty content.
write_json_file() { # path json
  local tmp
  [ -n "$2" ] || return 1
  tmp="$(mktemp "$RUNS_DIR/.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '%s\n' "$2" >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$1" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

save_run() { # path [run-id]: replaces .instances, keeps the other keys
  local inst new
  inst="$(record_json "${2:-}")" || return 1
  new="$(jq --argjson inst "$inst" '.instances = $inst' "$1")" || return 1
  write_json_file "$1" "$new"
}

valid_run_file() {
  jq -e '(.instances | type == "array") and all(.instances[]; type == "object")' "$1" >/dev/null 2>&1
}

load_run() { # path [run-id] -> appends to the I_* arrays; returns 1 when the file is unreadable
  local n u s st v
  valid_run_file "$1" || return 1
  while IFS=$'\x1f' read -r n u s st v _; do
    I_NAME+=("$n") I_UUID+=("$u") I_SERIAL+=("$s") I_STATUS+=("$st") E_RUN+=("${2:-}") I_VSTOP+=("$v")
    if [ "$v" = "1" ] && [ -n "$u" ]; then KNOWN_GONE["$u"]=1; fi
  done < <(jq -r '.instances[] | [(.name // ""), (.uuid // ""), (.serial // ""), (.status // ""),
    (if .stop_verified == true then "1" else "0" end), "."] | map(tostring) | join("\u001f")' "$1")
}

# A run record whose every entry is in a final status, and whose every entry
# with a UUID is recorded as verified stopped.
run_fully_stopped() { # path
  jq -e '(.instances | type == "array")
    and all(.instances[]; (.status // "") as $s
      | ["STOPPED", "START_FAILED", "BOOT_FAILED", "TIMEOUT", "ADB_FAILED"] | index($s) != null)
    and all(.instances[] | select(.uuid != null); .stop_verified == true)' "$1" >/dev/null 2>&1
}

record_prefix() { # path -> the recorded prefix, or empty
  jq -r '.prefix // empty | tostring' "$1" 2>/dev/null || true
}

latest_run_id() {
  local f id best=""
  [ -d "$RUNS_DIR" ] || return 0
  for f in "$RUNS_DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    [[ "$id" =~ $RUN_ID_RE ]] || continue
    if [[ "$id" > "$best" ]]; then best="$id"; fi
  done
  printf '%s' "$best"
}

check_run_flag() { # run-id (a run with no record here is looked up by name later)
  [[ "$1" =~ $RUN_ID_RE ]] || config_error "invalid run id '$1': expected YYYYMMDDHHMMSS-xxxxxxxx, as printed by start"
}

# Start time of a process, as "ps" prints it (procps and BSD ps both know lstart).
proc_start_time() { # pid
  # Fixed time zone and locale: start and stop may run with different settings.
  TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'
}

# PID of a start still running for this run, or empty. The pid file holds the
# pid and the process start time: a reused pid has another start time.
# The pid file is removed by start itself when it exits; stop never removes it.
active_start_pid() { # run-id
  local pid="" started="" now
  [ -r "$(pid_file "$1")" ] || return 0
  { IFS= read -r pid; IFS= read -r started; } 2>/dev/null <"$(pid_file "$1")" || true
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  now="$(proc_start_time "$pid")" || now=""
  # Two known start times: equal means the start, different means pid reuse.
  if [ -n "$started" ] && [ -n "$now" ]; then
    [ "$now" = "$started" ] || return 0
    printf '%s' "$pid"
    return 0
  fi
  # Start time unknown ("ps" without lstart): the pid is the start only if the
  # process runs fanout.sh; when even that cannot be read, count it as the start.
  local args=""
  if [ -r "/proc/$pid/cmdline" ]; then
    args="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" || args=""
  fi
  if [ -z "$args" ]; then args="$(ps -o args= -p "$pid" 2>/dev/null)" || args=""; fi
  if [ -n "$args" ] && [[ "$args" != *fanout.sh* ]]; then return 0; fi
  printf '%s' "$pid"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
new_run_id() {
  local hex
  while :; do
    hex="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    [[ "$hex" =~ ^[0-9a-f]{8}$ ]] || config_error "cannot read 4 random bytes from /dev/urandom"
    RUN_ID="$(date -u +%Y%m%d%H%M%S)-$hex"
    [ -e "$(state_file "$RUN_ID")" ] || break
  done
}

# The project directory must be writable: checked before any gmsaas start call.
prepare_runs_dir() {
  local probe
  mkdir -p "$RUNS_DIR" 2>/dev/null ||
    config_error "cannot create $RUNS_DIR: the project directory must be writable"
  if [ ! -e "$RUNS_DIR/.gitignore" ]; then
    printf '*\n' >"$RUNS_DIR/.gitignore" 2>/dev/null || config_error "cannot write in $RUNS_DIR: the project directory must be writable"
  fi
  probe="$(mktemp "$RUNS_DIR/.tmp.XXXXXX" 2>/dev/null)" ||
    config_error "cannot write in $RUNS_DIR: the project directory must be writable"
  rm -f "$probe"
}

# A listed instance belongs to the run: a recorded UUID, or a name ending in
# -<run-id>-<index>. Uses the last live_list.
run_has_listed_instance() { # run-id record-path
  local n u re="-${1}-[0-9]+\$"
  for n in "${!LIVE_BY_NAME[@]}"; do
    if [[ "$n" =~ $re ]] && is_alive "${LIVE_BY_NAME[$n]}"; then return 0; fi
  done
  if valid_run_file "$2"; then
    while IFS= read -r u; do
      if is_alive "$u"; then return 0; fi
    done < <(jq -r '.instances[] | .uuid // empty' "$2")
  fi
  return 1
}

# A listed instance carries one of the names recorded in the run record.
run_name_listed() { # record-path
  local n
  while IFS= read -r n; do
    if [ -n "$n" ] && [ -n "${LIVE_BY_NAME[$n]+x}" ] && is_alive "${LIVE_BY_NAME[$n]}"; then return 0; fi
  done < <(jq -r '.instances[] | .name // empty' "$1" 2>/dev/null)
  return 1
}

# The files of a run (.json, .stop, .pid) are deleted when its record is more
# than RECORD_MAX_AGE_DAYS days old and the preflight list shows no instance of
# that run. An instance cannot run longer than 28800 minutes (20 days).
# Old .stop and .pid files without a record go too. Needs the preflight list.
prune_old_records() {
  local f id
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(basename "$f")"; id="${id%.*}"
    [[ "$id" =~ $RUN_ID_RE ]] || continue
    if [ "${f##*.}" != "json" ] && [ -e "$(state_file "$id")" ]; then continue; fi
    if run_has_listed_instance "$id" "$(state_file "$id")"; then continue; fi
    rm -f "$(state_file "$id")" "$(stop_marker "$id")" "$(pid_file "$id")" 2>/dev/null || true
    log "deleted the files of run $id (older than $RECORD_MAX_AGE_DAYS days, no instance listed)"
  done < <(find "$RUNS_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.stop' -o -name '*.pid' \) \
    -mtime +"$RECORD_MAX_AGE_DAYS" 2>/dev/null)
}

count_status() { # status -> number of instances with it
  local i c=0
  for i in "${!I_STATUS[@]}"; do [ "${I_STATUS[i]}" != "$1" ] || c=$((c + 1)); done
  printf '%d' "$c"
}

# Instances of this run in the last live list, by name: <prefix>-<run-id>-<index>.
# Entries of the run take their UUID; unknown ones are appended.
sweep_run_names() {
  local n u i found re="^${PREFIX}-${RUN_ID}-[0-9]+\$"
  for n in "${!LIVE_BY_NAME[@]}"; do
    [[ "$n" =~ $re ]] || continue
    u="${LIVE_BY_NAME[$n]}"
    is_alive "$u" || continue
    found=0
    for i in "${!I_NAME[@]}"; do
      if [ "${I_NAME[i]}" = "$n" ]; then
        found=1
        [ -n "${I_UUID[i]}" ] || I_UUID[i]="$u"
      fi
    done
    if [ "$found" -eq 0 ] && ! has_uuid "$u"; then
      I_NAME+=("$n") I_UUID+=("$u") I_SERIAL+=("") I_STATUS+=("START_FAILED") I_LIVE+=("") I_VSTOP+=(0) I_SEEN+=(1)
    fi
  done
}

# Stops every instance of the run: by recorded UUID and by name
# <prefix>-<run-id>-<index> in a live list (covers a UUID not yet written).
teardown_run_all() {
  local i
  local -a targets=()
  if live_list; then sweep_run_names; fi
  # An entry without a UUID that is still starting: its start call was cut.
  for i in "${!I_NAME[@]}"; do
    if [ -z "${I_UUID[i]}" ] && [[ "$FINAL_STATUSES" != *" ${I_STATUS[i]} "* ]]; then I_STATUS[i]="START_FAILED"; fi
  done
  for i in "${!I_UUID[@]}"; do [ -z "${I_UUID[i]}" ] || targets+=("${I_UUID[i]}"); done
  local rc=0
  stop_and_verify "${targets[@]}" || rc=1
  mark_stopped
  save_run "$(state_file "$RUN_ID")" || log "cannot update $(state_file "$RUN_ID")"
  return "$rc"
}

# A "stop" for this run from another shell: tear everything down, exit 5.
check_stop_marker() {
  [ -e "$(stop_marker "$RUN_ID")" ] || return 0
  log "a stop was requested for run $RUN_ID from another shell"
  teardown_and_finish 5 "a stop was requested for run $RUN_ID"
}

# Wait between two boot polls, one second at a time, watching for a stop request.
nap_watch() {
  local k
  for ((k = 0; k < $1; k++)); do
    check_stop_marker
    nap 1
  done
}

start_instances() {
  local i name uuid
  for ((i = 0; i < COUNT; i++)); do
    check_stop_marker
    name="$PREFIX-$RUN_ID-$((i + 1))"
    I_NAME+=("$name") I_UUID+=("") I_SERIAL+=("") I_STATUS+=("STARTING") I_LIVE+=("") I_VSTOP+=(0) I_SEEN+=(0)
    save_run "$(state_file "$RUN_ID")"
    STARTED_ANY=1
    GM_INDEX="$i"
    gm instances start --no-wait --max-run-duration "$DURATION" "$RECIPE" "$name"
    uuid=""
    if [ "$GM_RC" -eq 0 ]; then uuid="$(jq -r '.instance.uuid // empty' <<<"$GM_OUT")"; fi
    if [ -n "$uuid" ]; then
      I_UUID[i]="$uuid"
      log "$name: started ($uuid)"
    else
      I_STATUS[i]="START_FAILED"
      log "$name: start failed: ${GM_ERR_MSG:-no instance UUID in the gmsaas output}"
    fi
    # Stored: a signal handler no longer needs the output of this call.
    GM_KIND="" GM_INDEX=""
    save_run "$(state_file "$RUN_ID")"
  done
}

any_starting() {
  local i
  for i in "${!I_STATUS[@]}"; do [ "${I_STATUS[i]}" != "STARTING" ] || return 0; done
  return 1
}

poll_boot() {
  local p i u st
  for ((p = 1; p <= BOOT_POLLS; p++)); do
    any_starting || break
    check_stop_marker
    if live_list; then
      adopt_by_name || true
      for i in "${!I_NAME[@]}"; do
        u="${I_UUID[i]}"
        [ "${I_STATUS[i]}" = "STARTING" ] && [ -n "$u" ] || continue
        if ! is_alive "$u"; then
          if [ "${I_SEEN[i]:-0}" = "1" ]; then
            I_STATUS[i]="BOOT_FAILED"
            log "${I_NAME[i]}: no longer listed (BOOT_FAILED)"
          elif [ "${I_LIVE[i]}" != "NOT_LISTED" ]; then
            I_LIVE[i]="NOT_LISTED"
            log "${I_NAME[i]}: not listed yet"
          fi
          continue
        fi
        I_SEEN[i]=1
        st="${LIVE_STATE[$u]}"
        if [ "$st" != "${I_LIVE[i]}" ]; then log "${I_NAME[i]}: $st"; I_LIVE[i]="$st"; fi
        if [ "$st" = "ONLINE" ]; then
          I_STATUS[i]="BOOTED"
        elif [[ "$STARTING_STATES" != *" $st "* ]]; then
          I_STATUS[i]="BOOT_FAILED"
          log "${I_NAME[i]}: left the starting states as $st (BOOT_FAILED)"
        fi
      done
      save_run "$(state_file "$RUN_ID")"
    else
      log "boot poll $p/$BOOT_POLLS: cannot list instances ($GM_ERR_MSG)"
    fi
    any_starting || break
    if [ "$p" -lt "$BOOT_POLLS" ]; then nap_watch "$POLL_INTERVAL"; fi
  done
  for i in "${!I_STATUS[@]}"; do
    if [ "${I_STATUS[i]}" = "STARTING" ]; then
      I_STATUS[i]="TIMEOUT"
      log "${I_NAME[i]}: still starting, or still not listed, after $BOOT_POLLS polls (TIMEOUT)"
    fi
  done
}

connect_adb() {
  local i port="$BASE_PORT" extra=0 serial
  check_stop_marker
  for i in "${!I_NAME[@]}"; do
    [ "${I_STATUS[i]}" = "BOOTED" ] || continue
    while :; do
      if [ "$port" -gt 65535 ]; then
        I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: no local port left below 65536 (ADB_FAILED)"; break
      fi
      check_stop_marker
      gm instances adbconnect --adb-serial-port "$port" "${I_UUID[i]}"
      if [ "$GM_RC" -eq 0 ]; then
        serial="$(jq -r '.instance.adb_serial // empty' <<<"$GM_OUT")"
        port=$((port + 1))
        if [ -z "$serial" ] || [ "$serial" = "0.0.0.0" ]; then
          I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: adbconnect returned no serial (ADB_FAILED)"
        else
          I_SERIAL[i]="$serial"; log "${I_NAME[i]}: ADB connected as $serial"
        fi
        break
      elif [ "$GM_RC" -eq 11 ]; then
        if [ "$extra" -ge "$MAX_EXTRA_PORTS" ]; then
          I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: port $port busy, and $MAX_EXTRA_PORTS ports were already skipped (ADB_FAILED)"; break
        fi
        log "port $port is busy, trying $((port + 1))"
        port=$((port + 1)) extra=$((extra + 1))
      elif [ "$GM_RC" -eq 13 ]; then
        # Already connected on another port: read the serial it has.
        gm instances get "${I_UUID[i]}"
        serial=""
        if [ "$GM_RC" -eq 0 ]; then serial="$(jq -r '.instance.adb_serial // empty' <<<"$GM_OUT")"; fi
        if [ -n "$serial" ] && [ "$serial" != "0.0.0.0" ]; then
          I_SERIAL[i]="$serial"; log "${I_NAME[i]}: already connected to ADB as $serial"
        else
          I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: connected on another port, but no serial could be read (ADB_FAILED)"
        fi
        break
      else
        I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: adbconnect failed: $GM_ERR_MSG (ADB_FAILED)"; break
      fi
    done
  done
  save_run "$(state_file "$RUN_ID")"
}

# Watchdog: after LIMIT seconds, writes FLAG and kills PID. It runs in the
# background and is ended by stop_watchdog; its own sleep is killed with it, so
# nothing is left behind. Sets WD_PID to the watchdog pid.
# SIGKILL: during a teardown INT, TERM and HUP are ignored, and the calls it
# makes inherit that, so a TERM would not end them.
start_watchdog() { # pid limit flag
  (
    trap 'kill -KILL "$s" 2>/dev/null; exit 0' TERM
    sleep "$2" & s=$!
    wait "$s"
    : >"$3"
    kill -KILL "$1" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  WD_PID=$!
}

stop_watchdog() { # watchdog-pid
  [ -n "$1" ] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# "adb devices", run like the gmsaas calls (background + wait, so a signal is
# handled at once), killed after ADB_DEVICES_TIMEOUT seconds: a hung adb then
# counts as "no device listed". Its output is left in $WORK_DIR/adb.out; call it
# directly, not in "$(...)": a subshell would delay the trap until it ends.
adb_devices() {
  local out="$WORK_DIR/adb.out"
  : >"$out"
  "$ADB_BIN" devices >"$out" 2>/dev/null </dev/null &
  ADB_PID=$!
  start_watchdog "$ADB_PID" "$ADB_DEVICES_TIMEOUT" "$WORK_DIR/adb.timeout"
  ADB_WD="$WD_PID"
  if ! wait "$ADB_PID"; then :; fi
  ADB_PID=""
  stop_watchdog "$ADB_WD"
  ADB_WD=""
}

verify_adb() {
  local a i out pending adb_started=0 retry_sleep
  retry_sleep=$(( POLL_INTERVAL < 2 ? POLL_INTERVAL : 2 ))
  for ((a = 1; a <= ADB_CHECKS; a++)); do
    check_stop_marker
    adb_devices
    out="$(cat "$WORK_DIR/adb.out" 2>/dev/null)" || out=""
    pending=0
    for i in "${!I_NAME[@]}"; do
      [ "${I_STATUS[i]}" = "BOOTED" ] || continue
      if grep -qxF -- "${I_SERIAL[i]}"$'\t'"device" <<<"$out"; then
        I_STATUS[i]="ONLINE"; log "${I_NAME[i]}: ONLINE on ${I_SERIAL[i]}"
      else
        pending=1
      fi
    done
    [ "$pending" -eq 1 ] || break
    if [ "$adb_started" -eq 0 ] && ! grep -q $'\t' <<<"$out"; then
      log "adb devices lists no device: running gmsaas adb start"
      gm adb start
      [ "$GM_RC" -eq 0 ] || log "gmsaas adb start: $GM_ERR_MSG"
      adb_started=1
      continue
    fi
    if [ "$a" -lt "$ADB_CHECKS" ]; then nap "$retry_sleep"; fi
  done
  for i in "${!I_NAME[@]}"; do
    if [ "${I_STATUS[i]}" = "BOOTED" ]; then
      I_STATUS[i]="ADB_FAILED"; log "${I_NAME[i]}: ${I_SERIAL[i]} not shown as device by adb devices (ADB_FAILED)"
    fi
  done
  save_run "$(state_file "$RUN_ID")"
}

finish_start() {
  local i usable total started_failed timeouts
  local -a failed=()
  check_stop_marker
  usable="$(count_status ONLINE)"
  total="${#I_NAME[@]}"
  if [ "$usable" -lt "$MIN" ]; then
    if [ "$usable" -ge 1 ]; then
      teardown_and_finish 1 "only $usable instance(s) usable, fewer than --min $MIN"
    fi
    started_failed="$(count_status START_FAILED)"
    timeouts="$(count_status TIMEOUT)"
    if [ "$started_failed" -eq "$total" ]; then
      teardown_and_finish 3 "no instance could be created (gmsaas instances start failed for each)"
    elif [ "$timeouts" -ge 1 ]; then
      teardown_and_finish 4 "no instance usable: $timeouts still starting after $BOOT_POLLS polls"
    fi
    teardown_and_finish 5 "no instance usable (boot or ADB failures)"
  fi

  # Last sweep by name: an instance of this run that a failed start call created
  # may show up only now.
  if live_list; then sweep_run_names; else log "cannot list instances for the last sweep ($GM_ERR_MSG)"; fi
  for i in "${!I_NAME[@]}"; do
    if [ "${I_STATUS[i]}" != "ONLINE" ] && [ -n "${I_UUID[i]}" ]; then failed+=("${I_UUID[i]}"); fi
  done
  if ! stop_and_verify "${failed[@]}"; then
    teardown_and_finish 5 "the stop of a failed instance could not be verified at first, so the whole run was stopped, healthy instances included"
  fi
  mark_stopped
  save_run "$(state_file "$RUN_ID")"
  check_stop_marker

  # Normal end: the result is committed; signals no longer tear the run down.
  trap '' INT TERM HUP
  log "$usable of $total instance(s) usable (run $RUN_ID)"
  warn_unlisted_start_failures
  if emit ""; then
    START_ACTIVE=0
    exit 0
  fi
  # Torn down here, once: on_exit must not do it again.
  START_ACTIVE=0
  log "error: the result could not be printed (standard output closed): stopping every instance of run $RUN_ID"
  if teardown_run_all; then
    log "$(teardown_summary)"
    exit 5
  fi
  log "$(not_verified_message)"
  exit 6
}

cmd_start() {
  resolve_start_settings
  resolve_intervals
  prepare_runs_dir
  if ! live_list; then finish 3 "gmsaas failed: $GM_ERR_MSG"; fi
  prune_old_records
  resolve_adb
  new_run_id
  # The pid file comes first: a stop that finds the record also finds the start.
  PID_FILE="$(pid_file "$RUN_ID")"
  printf '%s\n%s\n' "$$" "$(proc_start_time "$$")" >"$PID_FILE" 2>/dev/null || config_error "cannot write $PID_FILE: the project directory must be writable"
  write_json_file "$(state_file "$RUN_ID")" "$(jq -n --arg run "$RUN_ID" --arg prefix "$PREFIX" \
    --arg recipe "$RECIPE" --argjson d "$DURATION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{run_id: $run, created_at: $at, prefix: $prefix, recipe: $recipe, max_run_duration_minutes: $d, instances: []}')" ||
    config_error "cannot write $(state_file "$RUN_ID"): the project directory must be writable"
  START_ACTIVE=1
  # Contract: the run id reaches standard error before any instance is started,
  # so a caller whose start is killed can still run "stop --run <run-id>".
  log "run $RUN_ID (stop it with: fanout.sh stop --run $RUN_ID)"
  log "run $RUN_ID: starting $COUNT instance(s) of recipe $RECIPE (max run duration $DURATION minutes)"
  start_instances
  poll_boot
  connect_adb
  verify_adb
  finish_start
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
# stop: the lookup of the runs' instances by name, on the last list (which must
# have succeeded): <any prefix>-<run-id>-<index> for each run, and, with
# --all-mine, <prefix>-<run-id>-<index> for every run id. Sets LOOKUP_DONE.
stop_name_lookup() { # run-id...
  local id n u
  for id in "$@"; do add_run_names "$id" "$id"; done
  if [ "$F_ALL_MINE" -eq 1 ]; then
    # Unrecorded instances named <prefix>-<run-id>-<index>, whoever started them.
    while IFS= read -r n; do
      [ -n "$n" ] && [[ "$n" =~ ^${PREFIX}-[0-9]{14}-[0-9a-f]{8}-[0-9]+$ ]] || continue
      u="${LIVE_BY_NAME[$n]}"
      is_alive "$u" || continue
      has_uuid "$u" && continue
      I_NAME+=("$n") I_UUID+=("$u") I_SERIAL+=("") I_STATUS+=("UNKNOWN") E_RUN+=("") I_VSTOP+=(0)
    done < <(printf '%s\n' "${!LIVE_BY_NAME[@]}" | sort)
  fi
  LOOKUP_DONE=1
}

# Appends the live instances named <any prefix>-<run-id>-<index> that no entry
# carries yet (sorted by name). An entry with that name and no UUID takes it.
add_run_names() { # run-id entry-run-tag
  local n u i re="-${1}-[0-9]+\$"
  while IFS= read -r n; do
    [ -n "$n" ] && [[ "$n" =~ $re ]] || continue
    u="${LIVE_BY_NAME[$n]}"
    is_alive "$u" || continue
    has_uuid "$u" && continue
    for i in "${!I_NAME[@]}"; do
      if [ "${I_NAME[i]}" = "$n" ] && [ -z "${I_UUID[i]}" ]; then I_UUID[i]="$u"; continue 2; fi
    done
    I_NAME+=("$n") I_UUID+=("$u") I_SERIAL+=("") I_STATUS+=("UNKNOWN") E_RUN+=("$2") I_VSTOP+=(0)
  done < <(printf '%s\n' "${!LIVE_BY_NAME[@]}" | sort)
}

cmd_status() {
  local i u st f have_record=1
  if [ -n "$F_RUN" ]; then check_run_flag "$F_RUN"; RUN_ID="$F_RUN"; else RUN_ID="$(latest_run_id)"; fi
  if [ -z "$RUN_ID" ]; then log "no recorded run in $RUNS_DIR"; finish 0; fi
  f="$(state_file "$RUN_ID")"
  if [ ! -e "$f" ]; then
    have_record=0
  elif ! load_run "$f"; then
    finish 2 "the run record $f is unreadable or not a run record; run 'fanout.sh stop --run $RUN_ID' to stop the run by its instance names"
  fi
  if ! live_list; then finish 3 "gmsaas failed: $GM_ERR_MSG"; fi
  if [ "$have_record" -eq 0 ]; then
    log "run $RUN_ID has no record in this directory: looking up its instances by name in the account"
    add_run_names "$RUN_ID" ""
    [ "${#I_NAME[@]}" -gt 0 ] ||
      finish 2 "unknown run '$RUN_ID': no record in this directory, and no instance in the account carries this run id"
  fi
  adopt_by_name || true
  for i in "${!I_NAME[@]}"; do
    u="${I_UUID[i]}"
    [ -n "$u" ] || continue
    if is_alive "$u"; then
      st="${LIVE_STATE[$u]}"
      I_STATUS[i]="$(shown_state "$st")"
      if [ "$st" = "ONLINE" ] && [ -n "${LIVE_SERIAL[$u]}" ] && [ "${LIVE_SERIAL[$u]}" != "0.0.0.0" ]; then
        I_SERIAL[i]="${LIVE_SERIAL[$u]}"
      fi
    else
      resolve_unlisted "$i"
    fi
  done
  finish 0
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
cmd_stop() {
  local f id u n i pid rc=0 k orig rp no_record_run="" list_ok=1 t0=$SECONDS
  local -a run_ids=() targets=() cut=() still_cut=() found=() not_verified=()
  declare -A file_ok=() no_write=() has_record=()
  resolve_intervals
  if [ "$F_ALL_MINE" -eq 1 ]; then
    check_config_file
    resolve_prefix ""
    if ! live_list; then
      list_ok=0
      log "cannot list instances ($GM_ERR_MSG): stopping the runs recorded here only, without the name sweep"
    fi
    if [ -d "$RUNS_DIR" ]; then
      for f in "$RUNS_DIR"/*.json; do
        [ -e "$f" ] || continue
        id="$(basename "$f" .json)"
        [[ "$id" =~ $RUN_ID_RE ]] || continue
        # Only the runs recorded with the configured prefix. An unreadable record
        # is covered only by the name sweep of that prefix below.
        valid_run_file "$f" || continue
        rp="$(record_prefix "$f")"
        [ "$rp" = "$PREFIX" ] || continue
        # Already stopped: no running start, no entry in a non-final status,
        # every entry with a UUID verified, and no listed instance with one of
        # its names. Such a run gets no marker and no stop call.
        # Without a list the names cannot be checked: the verified stops decide.
        if [ -z "$(active_start_pid "$id")" ] && run_fully_stopped "$f" &&
          { [ "$list_ok" -eq 0 ] || ! run_name_listed "$f"; }; then continue; fi
        run_ids+=("$id")
      done
    fi
  else
    if [ -n "$F_RUN" ]; then check_run_flag "$F_RUN"; RUN_ID="$F_RUN"; else RUN_ID="$(latest_run_id)"; fi
    if [ -z "$RUN_ID" ]; then log "no recorded run in $RUNS_DIR: nothing to stop"; finish 0; fi
    run_ids=("$RUN_ID")
  fi
  for id in "${run_ids[@]}"; do
    if [ -e "$(state_file "$id")" ]; then has_record["$id"]=1; else has_record["$id"]=0; fi
  done

  # Ask a start still running for these runs to tear itself down, and wait for it:
  # while start is active it is the only writer of the run record.
  for id in "${run_ids[@]}"; do
    [ "${has_record[$id]}" -eq 1 ] || continue
    : >"$(stop_marker "$id")" 2>/dev/null || log "cannot write $(stop_marker "$id")"
  done
  for id in "${run_ids[@]}"; do
    pid="$(active_start_pid "$id")"
    [ -n "$pid" ] || continue
    log "start of run $id is still running (pid $pid): waiting for it to stop its instances (at most $ACTIVE_START_WAIT s)"
    for ((k = 0; k < ACTIVE_START_WAIT; k++)); do
      [ -n "$(active_start_pid "$id")" ] || break
      nap 1
    done
    if [ -n "$(active_start_pid "$id")" ]; then
      no_write["$id"]=1
      log "warning: the start of run $id (pid $pid) is still running after $ACTIVE_START_WAIT s: stop goes on without it and leaves the run record to that start, which may still rewrite it"
    fi
  done

  # The run records first: with a record, stop sends its stop calls even when
  # gmsaas cannot list the instances (then nothing can be verified: exit 6).
  list_ok=1
  if ! live_list; then
    list_ok=0
    log "cannot list instances ($GM_ERR_MSG): stopping by the UUIDs of the run records"
  fi
  for id in "${run_ids[@]}"; do
    f="$(state_file "$id")"
    file_ok["$id"]=0
    if [ "${has_record[$id]}" -eq 0 ] && [ "$list_ok" -eq 0 ]; then
      finish 3 "gmsaas failed: $GM_ERR_MSG; run $id has no record in this directory, so stop needs the instance list"
    fi
    if [ "${has_record[$id]}" -eq 0 ]; then
      no_record_run="$id"
      log "run $id has no record in this directory: stopping the instances that carry its run id in the account"
      log "warning: a start of run $id still running in another directory cannot be reached from here; it may start more instances: run stop from the directory that holds its record"
    elif load_run "$f" "$id"; then
      file_ok["$id"]=1
    else
      log "the run record $f is unreadable or not a run record: stopping the run by its instance names"
    fi
  done
  # Instances of the runs by name, on this list when it succeeded.
  [ "$list_ok" -eq 0 ] || stop_name_lookup "${run_ids[@]}"
  if [ -n "$no_record_run" ] && [ "${#I_NAME[@]}" -eq 0 ]; then
    finish 2 "unknown run '$no_record_run': no record in this directory, and no instance in the account carries this run id"
  fi
  for i in "${!I_UUID[@]}"; do [ -z "${I_UUID[i]}" ] || targets+=("${I_UUID[i]}"); done

  stop_and_verify "${targets[@]}" || rc=1
  mark_stopped
  # Every target not verified in this invocation (stop_and_verify is called again below).
  not_verified=(${STOP_REMAINING[@]+"${STOP_REMAINING[@]}"})

  # The list meant for the lookup by name failed: run the lookup on the last
  # list of the rounds when it succeeded, else on one more list; then stop and
  # verify what it finds.
  if [ "$LOOKUP_DONE" -eq 0 ]; then
    if [ "$LIVE_VALID" -eq 1 ] || live_list; then
      log "looking up the instances of the run by name on a later list"
      stop_name_lookup "${run_ids[@]}"
      found=()
      for i in "${!I_UUID[@]}"; do
        u="${I_UUID[i]}"
        # Only the UUIDs this lookup added (the first stop_and_verify had the others).
        if [ -n "$u" ] && [ -z "${STOP_TARGETS[$u]+x}" ] && [ -z "${KNOWN_GONE[$u]+x}" ]; then
          found+=("$u")
        fi
      done
      if [ "${#found[@]}" -gt 0 ]; then
        stop_and_verify "${found[@]}" || rc=1
        mark_stopped
        not_verified+=(${STOP_REMAINING[@]+"${STOP_REMAINING[@]}"})
      fi
    fi
  fi

  # A recorded name without a UUID, still starting: a start call was cut. Look
  # for that name in the list for START_CALL_WAIT seconds from the beginning of
  # this stop; adopt, stop and verify it when it appears.
  for i in "${!I_NAME[@]}"; do
    if [ -z "${I_UUID[i]}" ] && [ -n "${I_NAME[i]}" ] && [[ "$FINAL_STATUSES" != *" ${I_STATUS[i]} "* ]]; then cut+=("$i"); fi
  done
  if [ "${#cut[@]}" -gt 0 ]; then
    log "${#cut[@]} start call(s) of the run were cut: looking for their instances for up to $START_CALL_WAIT s"
  fi
  while [ "${#cut[@]}" -gt 0 ]; do
    found=() still_cut=()
    if live_list; then
      for i in "${cut[@]}"; do
        n="${I_NAME[i]}"
        if [ -n "${LIVE_BY_NAME[$n]+x}" ] && is_alive "${LIVE_BY_NAME[$n]}"; then
          I_UUID[i]="${LIVE_BY_NAME[$n]}"
          log "$n: found in the instance list by its name (${I_UUID[i]})"
          found+=("${I_UUID[i]}")
        else
          still_cut+=("$i")
        fi
      done
      cut=("${still_cut[@]}")
    fi
    if [ "${#found[@]}" -gt 0 ]; then
      stop_and_verify "${found[@]}" || rc=1
      mark_stopped
      not_verified+=(${STOP_REMAINING[@]+"${STOP_REMAINING[@]}"})
    fi
    [ "${#cut[@]}" -gt 0 ] || break
    [ $((SECONDS - t0)) -lt "$START_CALL_WAIT" ] || break
    nap 1
  done
  for i in "${cut[@]}"; do
    I_STATUS[i]="START_FAILED"
    log "warning: ${I_NAME[i]}: its start call failed and gmsaas did not list it, but the instance may still appear: run 'fanout.sh stop --run ${E_RUN[i]:-$RUN_ID}' when you are done"
  done

  for id in "${run_ids[@]}"; do
    [ "${file_ok[$id]}" -eq 1 ] && [ -z "${no_write[$id]+x}" ] || continue
    f="$(state_file "$id")"
    orig="$(jq -c '.instances' "$f" 2>/dev/null)" || orig=""
    if [ "$(record_json "$id")" != "$orig" ]; then
      save_run "$f" "$id" || log "cannot update $f"
    fi
  done

  if [ "$LOOKUP_DONE" -eq 0 ]; then
    # The lookup by name never ran on a successful list: a failed start call
    # without a UUID may have left an instance this stop cannot see.
    for i in "${!I_NAME[@]}"; do
      if [ -z "${I_UUID[i]}" ] && [ "${I_STATUS[i]}" = "START_FAILED" ]; then
        log "warning: ${I_NAME[i]}: its start call failed and gmsaas could not be listed, so the instance may still exist: run 'fanout.sh stop --run ${E_RUN[i]:-$RUN_ID}' again"
      fi
    done
  fi

  [ "$F_ALL_MINE" -eq 0 ] || RUN_ID=""
  STOP_REMAINING=(${not_verified[@]+"${not_verified[@]}"})
  if [ "$LOOKUP_DONE" -eq 0 ]; then
    finish 6 "$(no_list_message)"
  fi
  if [ "$rc" -ne 0 ]; then
    finish 6 "$(not_verified_message)"
  fi
  finish 0
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
F_COUNT="" F_RECIPE="" F_PREFIX="" F_DURATION="" F_BASE_PORT="" F_MIN="" F_RUN="" F_ALL_MINE=0

usage_error() {
  finish 2 "$1. Run 'fanout.sh --help' for usage."
}

parse_args() {
  local a flag val
  for a in "$@"; do
    case "$a" in -h|--help) usage 2>/dev/null || true; OUTPUT_DONE=1; exit 0 ;; esac
  done
  [ $# -gt 0 ] || usage_error "missing command (start, status or stop)"
  case "$1" in
    start|status|stop) CMD="$1"; shift ;;
    *) usage_error "unknown command '$1'" ;;
  esac
  while [ $# -gt 0 ]; do
    flag="$1" val=""
    case "$flag" in
      --all-mine=*) usage_error "--all-mine takes no value" ;;
      --*=*) val="${flag#*=}"; flag="${flag%%=*}"; shift ;;
      --all-mine) shift ;;
      --*)
        [ $# -ge 2 ] || usage_error "$flag needs a value"
        val="$2"; shift 2 ;;
      *) usage_error "unexpected argument '$flag'" ;;
    esac
    case "$CMD:$flag" in
      start:--count|start:--recipe|start:--prefix|start:--max-run-duration|start:--base-port|start:--min) ;;
      status:--run|stop:--run|stop:--all-mine) ;;
      *) usage_error "unknown option '$flag' for '$CMD'" ;;
    esac
    if [ "$flag" != "--all-mine" ] && [ -z "$val" ]; then usage_error "$flag needs a value"; fi
    case "$flag" in
      --count) F_COUNT="$val" ;;
      --recipe) F_RECIPE="$val" ;;
      --prefix) F_PREFIX="$val" ;;
      --max-run-duration) F_DURATION="$val" ;;
      --base-port) F_BASE_PORT="$val" ;;
      --min) F_MIN="$val" ;;
      --run) F_RUN="$val" ;;
      --all-mine) F_ALL_MINE=1 ;;
    esac
  done
  if [ -n "$F_RUN" ] && [ "$F_ALL_MINE" -eq 1 ]; then usage_error "--run and --all-mine cannot be used together"; fi
}

main() {
  # Exit 2 needs jq to print its JSON; check it before parsing anything else.
  if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; fi
  parse_args "$@"
  require_tools
  resolve_call_limit
  case "$CMD" in
    start) cmd_start ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
  esac
}

main "$@"
