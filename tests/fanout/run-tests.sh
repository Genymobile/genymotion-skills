#!/usr/bin/env bash
# Offline tests for scripts/fanout.sh.
#
# Every test runs the script BY PATH, in its own temporary project directory,
# with a clean environment (env -i) whose PATH is
# "<fakes>:<dir with a link to the bash running this suite>:/usr/bin:/bin".
# The fakes in tests/fanout/fakes/ stand in for gmsaas and adb; the runner
# aborts before any test unless both resolve to them.
#
# Usage: tests/fanout/run-tests.sh [name-filter]
#   name-filter: run only the tests whose name contains this text.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FAKES="$HERE/fakes"
SCRIPT="$REPO/scripts/fanout.sh"
FILTER="${1:-}"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/fanout-tests.XXXXXX")"
# Cleanup only; no assertion here. Some tests make directories read-only.
trap 'chmod -R u+w "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
# The script needs Bash 4.4+: put the bash running this suite first in line
# (on macOS /bin/bash is 3.2).
mkdir -p "$TMPROOT/bashbin"
ln -s "$BASH" "$TMPROOT/bashbin/bash"
SAFE_PATH="$FAKES:$TMPROOT/bashbin:/usr/bin:/bin"

RECIPE_A="11111111-1111-4111-8111-111111111111"
RECIPE_B="22222222-2222-4222-8222-222222222222"
RECIPE_C="33333333-3333-4333-8333-333333333333"
TOKEN_SENTINEL="tok-SENTINEL-7f3a9c41-never-print-me"

# --- Safety guard: never reach the real gmsaas or adb -----------------------
export PATH="$SAFE_PATH"
unset GENYMOTION_API_TOKEN
guard() {
  local g a
  g="$(PATH="$SAFE_PATH" command -v gmsaas || true)"
  a="$(PATH="$SAFE_PATH" command -v adb || true)"
  if [ "$g" != "$FAKES/gmsaas" ] || [ "$a" != "$FAKES/adb" ]; then
    echo "ABORT: gmsaas resolves to '$g' and adb to '$a'; both must be the fakes in $FAKES" >&2
    exit 2
  fi
}
guard
if ! command -v jq >/dev/null 2>&1; then echo "ABORT: jq is required by the tests" >&2; exit 2; fi
if [ ! -f "$SCRIPT" ]; then echo "ABORT: $SCRIPT not found" >&2; exit 2; fi


# --- Per-test state -----------------------------------------------------------
PROJ="" FAKE="" OUT="" ERR="" BG_OUT="" BG_ERR="" BG_PID="" RC=0 T_FAILED=0
ENVX=()   # extra environment for the script, NAME=value entries

new_project() {
  PROJ="$(mktemp -d "$TMPROOT/proj.XXXXXX")"
  FAKE="$PROJ/.fake-gmsaas"
  mkdir -p "$FAKE/instances" "$PROJ/.tmp"
  OUT="$PROJ/.out" ERR="$PROJ/.err" BG_OUT="$PROJ/.bgout" BG_ERR="$PROJ/.bgerr"
  : >"$OUT"; : >"$ERR"   # created now: a test may make the project directory read-only
  ENVX=()
}

base_env() {
  printf '%s\n' "PATH=$SAFE_PATH" "HOME=$PROJ" "TMPDIR=$PROJ/.tmp" "FAKE_GMSAAS_DIR=$FAKE" \
    "GENYMOTION_POLL_INTERVAL=0" "GENYMOTION_STOP_POLL_INTERVAL=0"
}

fail() { echo "    assertion failed: $*" >&2; T_FAILED=1; }

# One JSON object on stdout, nothing else.
one_json() { jq -e -s 'length == 1 and (.[0] | type == "object")' "$OUT" >/dev/null 2>&1; }
# Every gmsaas call so far used --format compactjson first, never -v, and
# every stop call used --no-wait.
calls_clean() {
  [ ! -s "$FAKE/calls.log" ] && return 0
  ! grep -v '^--format compactjson ' "$FAKE/calls.log" | grep -q . &&
    ! grep -Eq '(^| )(-v|--verbose)( |$)' "$FAKE/calls.log" &&
    ! grep ' instances stop ' "$FAKE/calls.log" | grep -vq -- ' --no-wait'
}

# fan ARGS...: run the script by path with the clean environment plus ENVX.
fan() {
  guard
  local -a env_list
  mapfile -t env_list < <(base_env)
  RC=0
  (cd "$PROJ" && env -i "${env_list[@]}" ${ENVX[@]+"${ENVX[@]}"} "$SCRIPT" "$@") \
    >"$OUT" 2>"$ERR" </dev/null || RC=$?
  if ! [[ " $* " == *" --help "* || " $* " == *" -h "* ]]; then
    one_json || fail "stdout is not exactly one JSON object for: $* (got: $(head -c 300 "$OUT"))"
  fi
  calls_clean || fail "a gmsaas call lacks '--format compactjson', has -v, or stops without --no-wait"
}

jf() { jq -e "$@" >/dev/null 2>&1; }            # test a JSON file: jf FILTER FILE
j() { jq -r "$@" "$OUT"; }                       # read the last stdout
jt() { jq -e "$@" "$OUT" >/dev/null 2>&1; }       # test the last stdout
rc_is() { [ "$RC" -eq "$1" ]; }
fake_count() { find "$FAKE/instances" -name '*.json' | wc -l; }
fake_none() { [ "$(fake_count)" -eq 0 ]; }
count_calls() { # pattern -> number of gmsaas calls matching it (0 when there is no log)
  local n
  n="$(grep -c -- "$1" "$FAKE/calls.log" 2>/dev/null)" || true
  printf '%d' "${n:-0}"
}
# A "sleep" child of process $1 (comm may be a full path, as on macOS).
sleeping_child() { ps -eo ppid=,comm= | awk -v p="$1" '{ c = $2; sub(".*/", "", c) } $1 == p && c == "sleep" { f = 1 } END { exit !f }'; }
lists_before_first_stop() { awk '/ instances stop /{exit} / instances list/{n++} END{print n+0}' "$FAKE/calls.log"; }
lists_after_last_stop() { awk '/ instances stop /{n=0; next} / instances list/{n++} END{print n+0}' "$FAKE/calls.log"; }
count_probe() { # yes|no -> number of fake start calls that saw / did not see the run id line
  local n
  n="$(grep -c -- "run-id-before-start=$1" "$FAKE/probe.log" 2>/dev/null)" || true
  printf '%d' "${n:-0}"
}
start_calls() { count_calls ' instances start '; }
stop_calls() { count_calls ' instances stop '; }
last_start() { grep ' instances start ' "$FAKE/calls.log" | tail -n 1; }
err_has() { grep -qF -- "$1" "$ERR"; }
state_file() { printf '%s/.genymotion/runs/%s.json' "$PROJ" "$1"; }
write_config() { printf '%s\n' "$1" >"$PROJ/.genymotion.json"; }
reset_logs() { : >"$FAKE/calls.log"; }
# bg_start ARGS...: run the script in the background (stdout/stderr in BG_OUT/BG_ERR).
bg_start() {
  local -a env_list
  mapfile -t env_list < <(base_env)
  guard
  (cd "$PROJ" && exec env -i "${env_list[@]}" ${ENVX[@]+"${ENVX[@]}"} "$SCRIPT" "$@") >"$BG_OUT" 2>"$BG_ERR" </dev/null &
  BG_PID=$!
}
bg_wait() { RC=0; wait "$BG_PID" 2>/dev/null || RC=$?; }
# Bounded waits (10 s, every 0.1 s).
wait_fake_at_least() { # N instances in the fake
  local i
  for ((i = 0; i < 100; i++)); do [ "$(fake_count)" -lt "$1" ] || return 0; sleep 0.1; done
  return 1
}
wait_calls_at_least() { # PATTERN N gmsaas calls
  local i
  for ((i = 0; i < 100; i++)); do [ "$(count_calls "$1")" -lt "$2" ] || return 0; sleep 0.1; done
  return 1
}
wait_sleeping_child() { # PID
  local i
  for ((i = 0; i < 100; i++)); do sleeping_child "$1" && return 0; sleep 0.1; done
  return 1
}
run_id_from() { # stderr file -> the run id of the "fanout: run <id> (stop it with: ...)" line
  sed -n 's/^fanout: run \([0-9]\{14\}-[0-9a-f]\{8\}\) (stop it with: fanout\.sh stop --run \1)$/\1/p' "$1" | head -n 1
}
fake_start() { # name: start an instance directly in the fake, outside the script
  env -i "PATH=$SAFE_PATH" "FAKE_GMSAAS_DIR=$FAKE" gmsaas --format compactjson instances start --no-wait "$RECIPE_A" "$1" >/dev/null
}
fake_has_name() { some_file_has "\"name\":\"$1\"" "$FAKE/instances"; }
contains() { [[ "$1" == *"$2"* ]]; }             # contains TEXT PART
no_file_has() { ! grep -rqF -- "$1" "$2" 2>/dev/null; }   # no_file_has TEXT PATH
some_file_has() { grep -rqF -- "$1" "$2" 2>/dev/null; }   # some_file_has TEXT PATH

# --- Tests ---------------------------------------------------------------------

t_normal_start_of_three() {
  local run n
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 3
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '[.instances[] | select(.status == "ONLINE")] | length == 3' || fail "3 instances ONLINE"
  jt '[.instances[].serial | select(. != null)] | unique | length == 3' || fail "3 distinct serials"
  jt 'has("error") | not' || fail "no error key"
  [ "$(start_calls)" -eq 3 ] || fail "3 start calls"
  while IFS= read -r line; do
    [[ "$line" == *" --no-wait "* ]] || fail "start call without --no-wait: $line"
    n="$(sed -n 's/.*--max-run-duration \([0-9]*\).*/\1/p' <<<"$line")"
    [ -n "$n" ] && [ "$n" -ge 1 ] && [ "$n" -le 28800 ] || fail "start call without a valid --max-run-duration: $line"
  done < <(grep ' instances start ' "$FAKE/calls.log")
  run="$(j .run_id)"
  [ -f "$(state_file "$run")" ] || fail "state file exists"
  grep -qx '\*' "$PROJ/.genymotion/runs/.gitignore" || fail "runs/.gitignore holds *"
  jt "[.instances[].name] == [\"agent-$run-1\", \"agent-$run-2\", \"agent-$run-3\"]" || fail "names are <prefix>-<run-id>-<index>"
  [ "$(fake_count)" -eq 3 ] || fail "fake runs 3 instances"
  fan stop --run "$run"
  rc_is 0 || fail "stop exit 0 (got $RC)"
  fake_none || fail "fake has no instance left"
  jt '[.instances[] | select(.status == "STOPPED")] | length == 3' || fail "stop reports 3 STOPPED"
  jf '[.instances[].status] == ["STOPPED","STOPPED","STOPPED"]' "$(state_file "$run")" || fail "state file says STOPPED"
}

t_partial_boot_failure() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=fail")
  fan start --count 3
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '[.instances[] | select(.status == "ONLINE")] | length == 2' || fail "2 ONLINE"
  jt '.instances[1].status == "BOOT_FAILED" and .instances[1].serial == null' || fail "index 2 BOOT_FAILED with null serial"
  no_file_has "$(j '.instances[1].name')" "$FAKE/instances" || fail "failed instance no longer in the fake"
  [ "$(fake_count)" -eq 2 ] || fail "the 2 healthy ones still run"
}

# Shared body of the interrupt tests. $1: signal; $2: expected exit code; $3: launcher prefix.
interrupt_case() {
  local sig="$1" want="$2" pid t0 run i
  local -a env_list launcher
  read -r -a launcher <<<"$3"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_POLL_INTERVAL=30"
        "FAKE_GMSAAS_BEHAVIOUR_1=slow" "FAKE_GMSAAS_BEHAVIOUR_2=slow" "FAKE_GMSAAS_BEHAVIOUR_3=slow")
  mapfile -t env_list < <(base_env)
  guard
  (cd "$PROJ" && exec ${launcher[@]+"${launcher[@]}"} env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 3) \
    >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  # Wait (bounded) until the script waits between two boot polls: a "sleep"
  # child of the script process. Signalling earlier would not test the wait.
  for ((i = 0; i < 100; i++)); do
    sleeping_child "$pid" && break
    sleep 0.1
  done
  sleeping_child "$pid" || fail "the script was waiting between two polls before the signal"
  [ "$(fake_count)" -eq 3 ] || fail "instances were booting before the signal"
  t0=$SECONDS
  kill "-$sig" "$pid"
  RC=0; wait "$pid" || RC=$?
  rc_is "$want" || fail "exit $want after SIG$sig (got $RC)"
  [ $((SECONDS - t0)) -lt 10 ] || fail "exited promptly, not after the 30 s wait ($((SECONDS - t0)) s)"
  one_json || fail "stdout is one JSON object"
  jt '.error | type == "string"' || fail "JSON has an error"
  jt ".error | test(\"interrupted by SIG$sig\")" || fail "JSON error says interrupted by SIG$sig"
  fake_none || fail "fake has no instance left"
  run="$(j .run_id)"
  jf '[.instances[].status] == ["STOPPED","STOPPED","STOPPED"]' "$(state_file "$run")" || fail "state file says STOPPED for all 3"
}

t_interrupt_sigterm() { interrupt_case TERM 143 ""; }

t_interrupt_sighup() { interrupt_case HUP 129 ""; }

t_interrupt_sigint() {
  if ! env --default-signal=INT true 2>/dev/null; then
    echo "    SKIP-VARIANT: env --default-signal is not available; the SIGINT variant was not run" >&2
    return 77
  fi
  interrupt_case INT 130 "env --default-signal=INT"
}

t_interrupt_before_uuid_recorded() {
  local pid i run
  local -a env_list
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_START_DELAY_2=2")
  mapfile -t env_list < <(base_env)
  guard
  (cd "$PROJ" && exec env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 3) >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  # Instance 2 exists in the fake, but its start call has not returned yet.
  for ((i = 0; i < 100; i++)); do [ "$(fake_count)" -ge 2 ] && break; sleep 0.05; done
  [ "$(fake_count)" -eq 2 ] || fail "instance 2 created before the signal"
  kill -TERM "$pid"
  RC=0; wait "$pid" || RC=$?
  rc_is 143 || fail "exit 143 (got $RC)"
  one_json || fail "stdout is one JSON object"
  fake_none || fail "fake has no instance left (found by name prefix)"
  [ "$(start_calls)" -eq 2 ] || fail "no third start call"
  jf '.instances[1].uuid != null' "$(state_file "$(j .run_id)")" || fail "instance 2 adopted by name into the state file"
  run="$(j .run_id)"
  jf '[.instances[].status] == ["STOPPED","STOPPED"]' "$(state_file "$run")" || fail "state file says STOPPED"
}

# SIGKILL: no trap can run. The run id printed on stderr before the first start
# call must be enough to stop everything from a new process.
t_sigkill_then_stop_by_logged_run_id() {
  local pid i run
  local -a env_list
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_POLL_INTERVAL=30" "FAKE_GMSAAS_STDERR_PROBE=$ERR"
        "FAKE_GMSAAS_BEHAVIOUR_1=slow" "FAKE_GMSAAS_BEHAVIOUR_2=slow")
  mapfile -t env_list < <(base_env)
  guard
  (cd "$PROJ" && exec env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 2) >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  for ((i = 0; i < 100; i++)); do
    [ "$(count_calls ' instances list')" -ge 2 ] && break
    sleep 0.1
  done
  [ "$(fake_count)" -eq 2 ] || fail "2 instances booting before SIGKILL"
  kill -KILL "$pid"
  RC=0; wait "$pid" 2>/dev/null || RC=$?
  [ "$RC" -eq 137 ] || fail "killed by SIGKILL (got $RC)"
  [ ! -s "$OUT" ] || fail "no JSON printed by a killed start"
  [ "$(fake_count)" -eq 2 ] || fail "the killed start left its 2 instances running"
  if [ "$(count_probe yes)" -ne 2 ] || [ "$(count_probe no)" -ne 0 ]; then
    fail "the run id line was on stderr before every instances start call"
  fi
  run="$(run_id_from "$ERR")"
  [ -n "$run" ] || fail "run id found on stderr"
  ENVX=()
  fan stop --run "$run"
  [ "$RC" -eq 0 ] || fail "stop --run <logged id> exit 0 (got $RC)"
  fake_none || fail "fake has no instance left after stop --run <logged id>"
}

# SIGKILL while a start call is in flight: the instance exists, its UUID is not
# recorded. stop --run must still find it by its recorded name.
t_sigkill_during_start_call_then_stop() {
  local pid i run
  local -a env_list
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_START_DELAY_2=2")
  mapfile -t env_list < <(base_env)
  guard
  (cd "$PROJ" && exec env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 3) >"$OUT" 2>"$ERR" </dev/null &
  pid=$!
  for ((i = 0; i < 100; i++)); do [ "$(fake_count)" -ge 2 ] && break; sleep 0.05; done
  [ "$(fake_count)" -eq 2 ] || fail "instance 2 created before SIGKILL"
  kill -KILL "$pid"
  RC=0; wait "$pid" 2>/dev/null || RC=$?
  [ "$RC" -eq 137 ] || fail "killed by SIGKILL (got $RC)"
  run="$(run_id_from "$ERR")"
  [ -n "$run" ] || fail "run id found on stderr"
  jf '.instances[1].uuid == null' "$(state_file "$run")" || fail "precondition: UUID of instance 2 not recorded"
  sleep 2   # let the orphaned start call finish, as it would in real life
  ENVX=()
  fan stop --run "$run"
  [ "$RC" -eq 0 ] || fail "stop --run exit 0 (got $RC)"
  fake_none || fail "fake has no instance left (instance 2 found by its recorded name)"
  jf '.instances[1].uuid != null and .instances[1].status == "STOPPED"' "$(state_file "$run")" ||
    fail "state file records the adopted UUID as STOPPED"
}

t_stop_twice() {
  local run before
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 2
  run="$(j .run_id)"
  fan stop --run "$run"
  rc_is 0 || fail "first stop exit 0 (got $RC)"
  before="$(cat "$(state_file "$run")")"
  reset_logs
  fan stop --run "$run"
  rc_is 0 || fail "second stop exit 0 (got $RC)"
  [ "$(stop_calls)" -eq 0 ] || fail "second stop makes no instances stop call"
  [ "$(cat "$(state_file "$run")")" = "$before" ] || fail "second stop leaves the state file unchanged"
  jt '[.instances[].status] == ["STOPPED","STOPPED"]' || fail "second stop reports STOPPED"
  fan stop
  rc_is 0 || fail "stop without --run (most recent run) exit 0 (got $RC)"
  [ "$(stop_calls)" -eq 0 ] || fail "no instances stop call either"
}

cap_case() { # description
  fan start --count 6
  rc_is 2 || fail "$1: exit 2 (got $RC)"
  err_has "--count 6 is above the cap of 5" || fail "$1: message names 6 and 5"
  err_has "GENYMOTION_MAX_INSTANCES" || fail "$1: message says how to raise the cap"
  [ "$(start_calls)" -eq 0 ] || fail "$1: zero start calls"
  jt '.error | test("6.*5")' || fail "$1: JSON error"
}

t_count_above_cap() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  cap_case "default cap"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_MAX_INSTANCES=3")
  fan start --count 4
  rc_is 2 || fail "env cap: exit 2 (got $RC)"
  err_has "--count 4 is above the cap of 3" || fail "env cap: message names 4 and 3"
  write_config '{"maxInstances": 2}'
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 3
  rc_is 2 || fail "file cap: exit 2 (got $RC)"
  err_has "--count 3 is above the cap of 2" || fail "file cap: message names 3 and 2"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls in total"
  write_config '{"maxInstances": 10}'
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_MAX_INSTANCES=5")
  cap_case "env cap 5 over file cap 10"
}

t_missing_config_noninteractive() {
  ENVX=("CI=true")
  fan start --count 1
  rc_is 2 || fail "exit 2 (got $RC)"
  err_has "Genymotion is not configured for unattended use: GENYMOTION_SAAS_RECIPE is not set." || fail "configuration message on stderr"
  err_has "See references/configuration.md for every setting." || fail "configuration message points to references/configuration.md"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
  jt '.run_id == null and .instances == []' || fail "run_id null, no instance"
  ENVX=("GENYMOTION_NONINTERACTIVE=1" "GENYMOTION_PLATFORM=saas")
  fan start
  rc_is 2 || fail "with platform saas and no recipe: exit 2 (got $RC)"
  ! ls "$PROJ"/.genymotion/runs/*.json >/dev/null 2>&1 || fail "no run state file written"
}

t_below_min() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=fail" "FAKE_GMSAAS_BEHAVIOUR_3=slow")
  fan start --count 3 --min 2
  rc_is 1 || fail "exit 1 (got $RC)"
  fake_none || fail "fake has no instance left"
  jt '.error | test("fewer than --min 2")' || fail "error in JSON"
  jt '[.instances[].status] == ["STOPPED","BOOT_FAILED","TIMEOUT"]' || fail "statuses STOPPED, BOOT_FAILED, TIMEOUT"
}

t_all_slow_timeout() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=slow" "FAKE_GMSAAS_BEHAVIOUR_2=slow")
  fan start --count 2
  rc_is 4 || fail "exit 4 (got $RC)"
  fake_none || fail "fake has no instance left"
  jt '[.instances[].status] == ["TIMEOUT","TIMEOUT"]' || fail "both TIMEOUT"
  # 1 preflight + 10 boot polls + 1 name-prefix sweep + 1 list before the stop calls.
  [ "$(lists_before_first_stop)" -eq 13 ] || fail "exactly 10 boot polls (got $(lists_before_first_stop) lists before the first stop)"
}

t_all_failed_exit5() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=fail" "FAKE_GMSAAS_BEHAVIOUR_2=vanish")
  fan start --count 2
  rc_is 5 || fail "exit 5 (got $RC)"
  jt '[.instances[].status] == ["BOOT_FAILED","BOOT_FAILED"]' || fail "both BOOT_FAILED"
  fake_none || fail "fake has no instance left"
}

t_start_call_failure_quota() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=startfail")
  fan start --count 3
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "START_FAILED" and .instances[1].uuid == null' || fail "index 2 START_FAILED without uuid"
  jt '.instances[0].status == "ONLINE" and .instances[2].status == "ONLINE"' || fail "others ONLINE"
  [ "$(start_calls)" -eq 3 ] || fail "3 start calls (no retry)"
  [ "$(fake_count)" -eq 2 ] || fail "the two others kept"
}

t_start_failure_but_created_is_stopped() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=startfail_created")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "START_FAILED"' || fail "index 2 START_FAILED"
  [ "$(fake_count)" -eq 1 ] || fail "the instance created despite the error was stopped"
}

t_all_start_failed_exit3() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=startfail" "FAKE_GMSAAS_BEHAVIOUR_2=startfail")
  fan start --count 2
  rc_is 3 || fail "exit 3 (got $RC)"
  jt '[.instances[].status] == ["START_FAILED","START_FAILED"]' || fail "both START_FAILED"
  fake_none || fail "fake has no instance"
}

t_auth_failure() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_AUTH_FAIL=1")
  fan start --count 2
  rc_is 3 || fail "exit 3 (got $RC)"
  err_has "Authentication failed: the API token is invalid" || fail "gmsaas error message relayed"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
  jt '.run_id == null and .instances == []' || fail "run_id null"
  ! ls "$PROJ"/.genymotion/runs/*.json >/dev/null 2>&1 || fail "no run state file"
}

t_precedence_recipe() {
  write_config "{\"saasRecipe\": \"$RECIPE_C\"}"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_B")
  fan start --recipe "$RECIPE_A"
  contains "$(last_start)" " $RECIPE_A " || fail "flag wins (got: $(last_start))"
  fan start
  contains "$(last_start)" " $RECIPE_B " || fail "env beats file"
  ENVX=("GENYMOTION_SAAS_RECIPE=")
  fan start
  contains "$(last_start)" " $RECIPE_C " || fail "file used when env is empty"
  rm -f "$PROJ/.genymotion.json"
  fan start
  rc_is 2 || fail "no default recipe: exit 2 (got $RC)"
}

t_precedence_prefix() {
  write_config "{\"saasRecipe\": \"$RECIPE_A\", \"instancePrefix\": \"filep\"}"
  ENVX=("GENYMOTION_INSTANCE_PREFIX=envp")
  fan start --prefix flagp
  jt '.instances[0].name | startswith("flagp-")' || fail "flag wins"
  fan start
  jt '.instances[0].name | startswith("envp-")' || fail "env beats file"
  ENVX=()
  fan start
  jt '.instances[0].name | startswith("filep-")' || fail "file beats default"
  write_config "{\"saasRecipe\": \"$RECIPE_A\"}"
  fan start
  jt '.instances[0].name | startswith("agent-")' || fail "default agent"
}

t_precedence_duration() {
  write_config "{\"saasRecipe\": \"$RECIPE_A\", \"maxRunDuration\": 9}"
  ENVX=("GENYMOTION_MAX_RUN_DURATION=8")
  fan start --max-run-duration 7
  contains "$(last_start)" "--max-run-duration 7 " || fail "flag wins"
  fan start
  contains "$(last_start)" "--max-run-duration 8 " || fail "env beats file"
  ENVX=()
  fan start
  contains "$(last_start)" "--max-run-duration 9 " || fail "file beats default"
  write_config "{\"saasRecipe\": \"$RECIPE_A\"}"
  fan start
  contains "$(last_start)" "--max-run-duration 60 " || fail "default 60"
}

t_precedence_base_port() {
  write_config "{\"saasRecipe\": \"$RECIPE_A\", \"adbBasePort\": 20000}"
  fan start
  jt '.instances[0].serial == "localhost:20000"' || fail "file base port"
  ENVX=("GENYMOTION_ADB_BASE_PORT=21000")
  fan start
  jt '.instances[0].serial == "localhost:21000"' || fail "env base port"
  fan start --base-port 22000
  jt '.instances[0].serial == "localhost:22000"' || fail "flag base port"
}

t_named_recipe() {
  write_config "{\"saasRecipe\": \"tablet\", \"recipes\": {\"phone\": \"$RECIPE_A\", \"tablet\": \"$RECIPE_B\"}}"
  fan start --recipe phone
  contains "$(last_start)" " $RECIPE_A " || fail "flag name resolves (exit $RC)"
  fan start
  contains "$(last_start)" " $RECIPE_B " || fail "file name resolves"
  reset_logs
  fan start --recipe watch
  rc_is 2 || fail "unknown name: exit 2 (got $RC)"
  err_has "Known names: phone, tablet" || fail "unknown name: lists the known names"
  [ "$(start_calls)" -eq 0 ] || fail "unknown name: zero start calls"
}

t_duration_bounds() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --max-run-duration 0
  rc_is 2 || fail "0 refused: exit 2 (got $RC)"
  err_has "minutes" || fail "0 refused: message says minutes"
  fan start --max-run-duration 28801
  rc_is 2 || fail "28801 refused: exit 2 (got $RC)"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_MAX_RUN_DURATION=0")
  fan start
  rc_is 2 || fail "0 from env refused: exit 2 (got $RC)"
  write_config '{"maxRunDuration": 28801}'
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start
  rc_is 2 || fail "28801 from file refused: exit 2 (got $RC)"
  fan start --max-run-duration 1.5
  rc_is 2 || fail "1.5 refused: exit 2 (got $RC)"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
  fan start --max-run-duration 28800
  rc_is 0 || fail "28800 accepted (exit $RC)"
  fan start --max-run-duration 1
  rc_is 0 || fail "1 accepted (exit $RC)"
}

t_platform() {
  write_config "{\"platform\": \"desktop\", \"saasRecipe\": \"$RECIPE_A\"}"
  fan start
  rc_is 2 || fail "desktop refused: exit 2 (got $RC)"
  err_has "GENYMOTION_PLATFORM=saas" || fail "desktop refused: hint GENYMOTION_PLATFORM=saas"
  [ "$(start_calls)" -eq 0 ] || fail "desktop refused: zero start calls"
  ENVX=("GENYMOTION_PLATFORM=saas")
  fan start
  rc_is 0 || fail "env saas overrides file desktop (exit $RC)"
  ENVX=("GENYMOTION_PLATFORM=cloud")
  fan start
  rc_is 2 || fail "unknown platform: exit 2 (got $RC)"
  write_config '{"desktopDevice": "Pixel 7 API 33"}'
  ENVX=()
  fan start
  rc_is 2 || fail "implied desktop refused: exit 2 (got $RC)"
  err_has "resolves to desktop" || fail "implied desktop refused: message"
}

t_busy_port_skipped() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BUSY_PORTS=15555 15557")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '[.instances[].serial] == ["localhost:15556","localhost:15558"]' || fail "serials skip the busy ports"
}

t_busy_ports_bounded() {
  local ports p
  ports=""; for ((p = 15555; p <= 15580; p++)); do ports+="$p "; done
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BUSY_PORTS=$ports")
  fan start --count 1
  rc_is 5 || fail "exit 5 (got $RC)"
  jt '.instances[0].status == "ADB_FAILED"' || fail "ADB_FAILED"
  [ "$(count_calls ' adbconnect ')" -eq 21 ] || fail "at most 21 adbconnect calls"
  fake_none || fail "fake has no instance left"
}

t_adb_failed_stopped() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=adboffline")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "ADB_FAILED" and .instances[1].serial == null' || fail "index 2 ADB_FAILED"
  [ "$(fake_count)" -eq 1 ] || fail "ADB_FAILED instance stopped"
}

t_adb_start_when_empty() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_ADB_NEEDS_START=1")
  fan start --count 1
  rc_is 0 || fail "exit 0 (got $RC)"
  [ "$(count_calls ' adb start')" -eq 1 ] || fail "gmsaas adb start was called once"
}

t_stop_all_mine() {
  local run rid="20261118171600-a3f19c02"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 1
  run="$(j .run_id)"
  # Unrecorded instances started outside the script.
  fake_start "agent-x-$rid-1"       # another prefix that starts with "agent-"
  fake_start "agent2-$rid-1"        # another prefix
  fake_start "agent-manual-1"       # our prefix, not a run name
  fake_start "agent-$rid-1"         # a run name with our prefix: must be stopped
  fan stop --all-mine
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.run_id == null' || fail "run_id null"
  fake_has_name "agent-x-$rid-1" || fail "agent-x-$rid-1 left alone"
  fake_has_name "agent2-$rid-1" || fail "agent2-$rid-1 left alone"
  fake_has_name "agent-manual-1" || fail "agent-manual-1 left alone"
  ! fake_has_name "agent-$rid-1" || fail "unrecorded agent-$rid-1 stopped"
  [ "$(fake_count)" -eq 3 ] || fail "exactly 3 instances left (got $(fake_count))"
  jf '[.instances[].status] == ["STOPPED"]' "$(state_file "$run")" || fail "recorded run stopped"
  jt "[.instances[] | select(.status == \"STOPPED\") | .name] | sort == ([\"agent-$rid-1\", \"agent-$run-1\"] | sort)" ||
    fail "output lists the 2 stopped instances"
  fan stop --all-mine --run "$run"
  rc_is 2 || fail "--run with --all-mine: exit 2 (got $RC)"
}

t_status_output() {
  local run
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=fail")
  fan start --count 2
  run="$(j .run_id)"
  fan status
  rc_is 0 || fail "status exit 0 (got $RC)"
  jt ".run_id == \"$run\"" || fail "status: run id"
  jt '.instances[0].status == "ONLINE" and .instances[0].serial == "localhost:15555" and .instances[1].status == "BOOT_FAILED"' || fail "status: ONLINE with serial, BOOT_FAILED kept"
  fan stop --run "$run"
  fan status --run "$run"
  jt '[.instances[].status] == ["STOPPED","BOOT_FAILED"]' || fail "status after stop: STOPPED, BOOT_FAILED kept"
}

t_no_recorded_run() {
  fan stop
  rc_is 0 || fail "stop with no run: exit 0 (got $RC)"
  jt '.run_id == null and .instances == []' || fail "stop with no run: null run"
  fan status
  rc_is 0 || fail "status with no run: exit 0 (got $RC)"
  fan stop --run 20261118171600-a3f19c02
  rc_is 2 || fail "unknown run: exit 2 (got $RC)"
  fan stop --run nonsense
  rc_is 2 || fail "malformed run id: exit 2 (got $RC)"
}

t_stop_unverified_exit6() {
  local run
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=stuckstop")
  fan start --count 1
  run="$(j .run_id)"
  fan stop --run "$run"
  rc_is 6 || fail "exit 6 (got $RC)"
  jt '.instances[0].status == "STOPPING"' || fail "status shows the live state"
  [ "$(lists_after_last_stop)" -eq 12 ] || fail "exactly 12 stop checks after the stop call (got $(lists_after_last_stop))"
  jt '.error | test("cloud.geny.io")' || fail "error mentions cloud.geny.io"
}

t_start_unverified_exit6() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=stuckstop" "FAKE_GMSAAS_BEHAVIOUR_2=adboffline")
  fan start --count 2 --min 2
  rc_is 6 || fail "exit 6 when a teardown stop cannot be verified (got $RC)"
}

t_token_never_leaks() {
  local run
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_API_TOKEN=$TOKEN_SENTINEL" "FAKE_GMSAAS_BEHAVIOUR_2=fail")
  : >"$PROJ/.all"
  fan start --count 2; cat "$OUT" "$ERR" >>"$PROJ/.all"
  run="$(j .run_id)"
  fan status; cat "$OUT" "$ERR" >>"$PROJ/.all"
  fan stop --run "$run"; cat "$OUT" "$ERR" >>"$PROJ/.all"
  fan start --count 99; cat "$OUT" "$ERR" >>"$PROJ/.all"
  ENVX+=("FAKE_GMSAAS_AUTH_FAIL=1")
  fan start; cat "$OUT" "$ERR" >>"$PROJ/.all"
  fan --help; cat "$OUT" "$ERR" >>"$PROJ/.all"
  no_file_has "$TOKEN_SENTINEL" "$PROJ/.all" || fail "sentinel absent from stdout/stderr"
  no_file_has "$TOKEN_SENTINEL" "$PROJ/.genymotion" || fail "sentinel absent from state files"
  no_file_has "$TOKEN_SENTINEL" "$FAKE/calls.log" || fail "sentinel absent from gmsaas argv"
  [ -s "$PROJ/.all" ] || fail "something was captured"
}

t_help() {
  fan --help
  rc_is 0 || fail "--help exit 0 (got $RC)"
  grep -q '^Usage:' "$OUT" || fail "--help prints usage on stdout"
  grep -q 'Exit codes:' "$OUT" || fail "--help lists exit codes"
  fan start -h
  rc_is 0 || fail "start -h exit 0 (got $RC)"
  [ ! -s "$FAKE/calls.log" ] || fail "-h makes no gmsaas call"
}

t_json_on_error_paths() {
  local -a cases=(
    "frobnicate"
    ""
    "start --bogus 1"
    "start --count"
    "start --count 0"
    "start --count abc"
    "start --min 0"
    "start --count 2 --min 3"
    "start --prefix -bad"
    "start --prefix waytoolongprefix_waytoolongprefix_x"
    "start --base-port 1023"
    "start --base-port 65535 --count 2"
    "start --base-port 65536"
    "status --all-mine"
    "stop --count 2"
    "stop --all-mine=yes"
  )
  local c
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  for c in "${cases[@]}"; do
    # shellcheck disable=SC2086 # word splitting of the case is intended
    fan $c
    rc_is 2 || fail "'$c': exit 2 (got $RC)"
    jt '.error | type == "string"' || fail "'$c': JSON error"
  done
  write_config '{not json'
  fan start
  rc_is 2 || fail "invalid .genymotion.json: exit 2 (got $RC)"
  write_config '{"maxInstances": 0}'
  fan start
  rc_is 2 || fail "maxInstances 0: exit 2 (got $RC)"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls on every error path"
}

# A PATH made only of links to the tools the script needs, so "missing" is real
# whatever the host has in /usr/bin.
tools_dir() { # dir tool...
  local d="$1" t p; shift
  mkdir -p "$d"
  for t in "$@"; do
    if [ "$t" = bash ]; then p="$BASH"; else p="$(command -v "$t")" || { fail "tool $t not found on the host"; continue; }; fi
    ln -s "$p" "$d/$t"
  done
}

t_missing_binaries() {
  local -a base=(bash jq mktemp cat tr od date grep tail head basename mv rm mkdir sleep ps sed)
  local nojq="$PROJ/.t-nojq" nogm="$PROJ/.t-nogm" noadb="$PROJ/.t-noadb"
  local -a without_jq=()
  local t
  for t in "${base[@]}"; do [ "$t" = jq ] || without_jq+=("$t"); done
  tools_dir "$nojq" "${without_jq[@]}"
  ln -s "$FAKES/gmsaas" "$nojq/gmsaas"
  tools_dir "$nogm" "${base[@]}"
  tools_dir "$noadb" "${base[@]}"
  ln -s "$FAKES/gmsaas" "$noadb/gmsaas"
  mkdir -p "$PROJ/.sdk-without-adb/platform-tools"
  [ "$T_FAILED" -eq 0 ] || return 0

  RC=0
  (cd "$PROJ" && env -i "PATH=$nojq" "HOME=$PROJ" "FAKE_GMSAAS_DIR=$FAKE" "GENYMOTION_SAAS_RECIPE=$RECIPE_A" \
    "$SCRIPT" start) >"$OUT" 2>"$ERR" </dev/null || RC=$?
  rc_is 2 || fail "jq missing: exit 2 (got $RC)"
  err_has "jq not found" || fail "jq missing: install hint"
  one_json || fail "jq missing: one JSON object (got: $(head -c 200 "$OUT"))"

  RC=0
  (cd "$PROJ" && env -i "PATH=$noadb" "HOME=$PROJ" "TMPDIR=$PROJ/.tmp" "FAKE_GMSAAS_DIR=$FAKE" "GENYMOTION_SAAS_RECIPE=$RECIPE_A" \
    "FAKE_GMSAAS_SDK_PATH=$PROJ/.sdk-without-adb" "$SCRIPT" start) >"$OUT" 2>"$ERR" </dev/null || RC=$?
  rc_is 2 || fail "adb missing (SDK without adb, none in PATH): exit 2 (got $RC)"
  err_has "android-sdk-path" || fail "adb missing: hint names the gmsaas Android SDK path"
  err_has "platform-tools" || fail "adb missing: platform-tools hint"
  one_json || fail "adb missing: one JSON object"

  RC=0
  (cd "$PROJ" && env -i "PATH=$nogm" "HOME=$PROJ" "GENYMOTION_SAAS_RECIPE=$RECIPE_A" \
    "$SCRIPT" stop) >"$OUT" 2>"$ERR" </dev/null || RC=$?
  rc_is 2 || fail "gmsaas missing: exit 2 (got $RC)"
  err_has "pip install gmsaas" || fail "gmsaas missing: pip hint"
  one_json || fail "gmsaas missing: one JSON object"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
}

t_defaults_match_contract() {
  local var doc help
  fan --help
  for var in GENYMOTION_MAX_RUN_DURATION GENYMOTION_MAX_INSTANCES GENYMOTION_INSTANCE_PREFIX GENYMOTION_ADB_BASE_PORT; do
    doc="$(grep -F "| \`$var\` |" "$REPO/references/configuration.md" | awk -F'|' '{print $(NF-1)}' | tr -d ' `')"
    help="$(grep -F "$var" "$OUT" | sed -n 's/.*(default: \([^ ,)]*\).*/\1/p' | head -n 1)"
    [ "${doc:-none}" = "${help:-missing}" ] || fail "$var: documented default '$doc' equals --help default '$help'"
  done
}

# --- Tests added for review round 1 ------------------------------------------------

# A closed output pipe (SIGPIPE) must not kill start without a teardown.
t_pipe_closed_tears_down() {
  local -a env_list
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_POLL_INTERVAL=1")
  mapfile -t env_list < <(base_env)
  guard
  RC=0
  (cd "$PROJ" || exit 99
   env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 3 2>&1 </dev/null | head -n 3 >/dev/null
   exit "${PIPESTATUS[0]}") || RC=$?
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || fail "'| head -n 3': exit neither 0 nor 2 (got $RC)"
  rc_is 5 || fail "'| head -n 3': exit 5, result could not be printed (got $RC)"
  fake_none || fail "'| head -n 3': fake has no instance left (got $(fake_count))"
  RC=0
  (cd "$PROJ" || exit 99
   env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 2 2>/dev/null </dev/null | true
   exit "${PIPESTATUS[0]}") || RC=$?
  [ "$RC" -ne 0 ] && [ "$RC" -ne 2 ] || fail "'| true': exit neither 0 nor 2 (got $RC)"
  fake_none || fail "'| true': fake has no instance left (got $(fake_count))"
}

t_stdout_closed_tears_down() {
  local -a env_list
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  mapfile -t env_list < <(base_env)
  guard
  RC=0
  (cd "$PROJ" && env -i "${env_list[@]}" "${ENVX[@]}" "$SCRIPT" start --count 2) >&- 2>"$ERR" </dev/null || RC=$?
  rc_is 5 || fail "stdout closed: exit 5 (got $RC)"
  fake_none || fail "stdout closed: fake has no instance left (got $(fake_count))"
  err_has "could not be printed" || fail "stdout closed: stderr says the result could not be printed"
}

t_corrupt_state_file() {
  local run v f
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  for v in truncated empty wrong_shape; do
    fan start --count 2
    run="$(j .run_id)"
    f="$(state_file "$run")"
    case "$v" in
      truncated) head -c 40 "$f" >"$f.cut" && mv "$f.cut" "$f" ;;
      empty) : >"$f" ;;
      wrong_shape) printf '{"instances": 5}\n' >"$f" ;;
    esac
    cp "$f" "$PROJ/.corrupt"
    fan status --run "$run"
    rc_is 2 || fail "$v: status exit 2 (got $RC)"
    jt '.error | test("unreadable")' || fail "$v: status error says unreadable"
    fan stop --run "$run"
    rc_is 0 || fail "$v: stop exit 0 (got $RC)"
    fake_none || fail "$v: fake has no instance left (got $(fake_count))"
    jt "[.instances[] | select(.status == \"STOPPED\") | .name] | sort == [\"agent-$run-1\", \"agent-$run-2\"]" ||
      fail "$v: stop reports the 2 instances found by name"
    cmp -s "$f" "$PROJ/.corrupt" || fail "$v: the unreadable state file was not replaced"
  done
}

# stop --run X while the start of X is still running: start tears down, exits 5.
t_stop_during_start() {
  local run
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_START_DELAY_2=3")
  bg_start start --count 3
  wait_fake_at_least 2 || fail "instance 2 created"
  run="$(run_id_from "$BG_ERR")"
  [ -n "$run" ] || fail "run id on stderr"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan stop --run "$run"
  rc_is 0 || fail "stop exit 0 (got $RC)"
  ! kill -0 "$BG_PID" 2>/dev/null || fail "stop returned only after the start of the run had exited"
  bg_wait
  rc_is 5 || fail "start exit 5 (got $RC)"
  jq -e '.error | test("stop was requested")' "$BG_OUT" >/dev/null 2>&1 || fail "start error says a stop was requested"
  fake_none || fail "fake has no instance left (got $(fake_count))"
  [ "$(start_calls)" -eq 2 ] || fail "no start call after the stop request (got $(start_calls))"
}

t_stop_call_retried() {
  local u n
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=fail" "FAKE_GMSAAS_STOP_FAIL_ONCE_2=1")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[0].status == "ONLINE" and .instances[1].status == "BOOT_FAILED"' || fail "ONLINE + BOOT_FAILED"
  [ "$(fake_count)" -eq 1 ] || fail "healthy instance kept, failed one gone (got $(fake_count))"
  u="$(j '.instances[1].uuid')"
  n="$(count_calls " instances stop --no-wait $u")"
  [ "$n" -ge 2 ] || fail "the failed stop was issued again (got $n stop calls)"
}

# A signal during a slow gmsaas call (not a start call) is handled at once.
t_interrupt_during_slow_call() {
  local t0
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_ADBCONNECT_DELAY=20")
  bg_start start --count 1
  wait_calls_at_least ' adbconnect ' 1 || fail "adbconnect call in flight"
  sleep 1
  t0=$SECONDS
  kill -TERM "$BG_PID"
  bg_wait
  rc_is 143 || fail "exit 143 (got $RC)"
  [ $((SECONDS - t0)) -le 6 ] || fail "exited within a few seconds, not after the 20 s call ($((SECONDS - t0)) s)"
  fake_none || fail "fake has no instance left (got $(fake_count))"
}

# A signal during a start call that fails but creates its instance: the
# handler waits for the call, then finds the instance by name.
t_interrupt_inflight_start_fails() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=startfail_created" "FAKE_GMSAAS_START_DELAY_2=2")
  bg_start start --count 3
  wait_fake_at_least 2 || fail "instance 2 created"
  kill -TERM "$BG_PID"
  bg_wait
  rc_is 143 || fail "exit 143 (got $RC)"
  fake_none || fail "fake has no instance left (got $(fake_count))"
  [ "$(start_calls)" -eq 2 ] || fail "no third start call"
}

# A signal during a start call whose instance the server creates late: the
# handler waits for the call to return, so that instance is known and stopped.
t_interrupt_inflight_start_server_side() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_CREATE_DELAY_2=3")
  bg_start start --count 3
  wait_calls_at_least ' instances start ' 2 || fail "start call 2 in flight"
  kill -TERM "$BG_PID"
  bg_wait
  rc_is 143 || fail "exit 143 (got $RC)"
  sleep 4   # past the server-side creation, whatever the script did
  fake_none || fail "fake has no instance left (got $(fake_count))"
}

# A signal during the wait between two stop checks of "stop" is handled at once,
# and the output gives the last live state, not the recorded one.
t_interrupt_during_stop() {
  local run t0
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_1=stuckstop")
  fan start --count 1
  run="$(j .run_id)"
  ENVX=("GENYMOTION_STOP_POLL_INTERVAL=30")
  bg_start stop --run "$run"
  wait_sleeping_child "$BG_PID" || fail "stop was waiting between two checks"
  t0=$SECONDS
  kill -TERM "$BG_PID"
  bg_wait
  rc_is 143 || fail "exit 143 (got $RC)"
  [ $((SECONDS - t0)) -le 5 ] || fail "exited promptly, not after the 30 s wait ($((SECONDS - t0)) s)"
  jq -e '.instances[0].status == "STOPPING" and .instances[0].serial == null' "$BG_OUT" >/dev/null 2>&1 ||
    fail "output gives the live state STOPPING (got: $(head -c 300 "$BG_OUT"))"
}

# A failed start call whose instance is listed only after start ended: start
# warns on stderr, and the final stop --run stops it.
t_late_instance_warned() {
  local run
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=startfail_created" "FAKE_GMSAAS_HIDE_LISTS_2=5")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  run="$(j .run_id)"
  jt '.instances[1].status == "START_FAILED" and .instances[1].uuid == null' || fail "index 2 START_FAILED without uuid"
  err_has "warning: agent-$run-2: its start call failed" || fail "warning on stderr names the instance"
  err_has "run 'fanout.sh stop --run $run' when you are done" || fail "warning gives the stop command"
  fan stop --run "$run"
  rc_is 0 || fail "stop exit 0 (got $RC)"
  fake_none || fail "fake has no instance left after stop --run (got $(fake_count))"
}

# A stale pid file whose pid now belongs to an unrelated process named like
# fanout: stop must not wait for it.
t_stale_pid_unrelated_process() {
  local run decoy i
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 1
  run="$(j .run_id)"
  bash -c 'exec -a "vim scripts/fanout.sh" sleep 60' &
  decoy=$!
  sleep 0.2
  printf '%s\n%s\n' "$decoy" "Mon Jan  1 00:00:00 2024" >"$PROJ/.genymotion/runs/$run.pid"
  ENVX=()
  bg_start stop --run "$run"
  for ((i = 0; i < 60; i++)); do kill -0 "$BG_PID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$BG_PID" 2>/dev/null; then
    fail "stop returned within 6 s (it waited for the unrelated process)"
    kill -TERM "$BG_PID" 2>/dev/null
  fi
  bg_wait
  kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null
  rc_is 0 || fail "stop exit 0 (got $RC)"
  fake_none || fail "fake has no instance left (got $(fake_count))"
}

t_readonly_project_dir() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  chmod 555 "$PROJ"
  fan start --count 2
  chmod 755 "$PROJ"
  rc_is 2 || fail "exit 2 (got $RC)"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
  [ ! -s "$FAKE/calls.log" ] || fail "checked before any gmsaas call"
  jt '.error | test("writable")' || fail "error says the project directory must be writable"
}

# A failed start call whose instance shows up only after the polls is still stopped.
t_late_instance_swept() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=startfail_created" "FAKE_GMSAAS_HIDE_LISTS_2=4")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "START_FAILED"' || fail "index 2 START_FAILED"
  [ "$(fake_count)" -eq 1 ] || fail "the late instance was stopped (got $(fake_count) instances)"
}

t_adbconnect_exit13_already_connected() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_ADB_ALREADY_1=16000")
  fan start --count 1
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[0].status == "ONLINE" and .instances[0].serial == "localhost:16000"' || fail "serial read with instances get"
  [ "$(count_calls ' instances get ')" -ge 1 ] || fail "instances get was called"
}

t_adbconnect_exit12_timeout() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_ADB_TIMEOUT_2=1")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "ADB_FAILED"' || fail "index 2 ADB_FAILED"
  [ "$(fake_count)" -eq 1 ] || fail "ADB_FAILED instance stopped"
}

t_adb_resolution() {
  local sdk="$PROJ/.sdk"
  mkdir -p "$sdk/platform-tools"
  # A wrapper standing for the SDK adb: it leaves a trace, then runs the fake adb.
  {
    echo '#!/bin/sh'
    echo "echo sdk >>\"\$FAKE_GMSAAS_DIR/sdk_adb.log\""
    echo "exec \"$FAKES/adb\" \"\$@\""
  } >"$sdk/platform-tools/adb"
  chmod +x "$sdk/platform-tools/adb"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_SDK_PATH=$sdk")
  fan start --count 1
  rc_is 0 || fail "SDK adb: exit 0 (got $RC)"
  [ -s "$FAKE/sdk_adb.log" ] || fail "SDK adb: the adb of the gmsaas Android SDK was used"
  err_has "using adb of the Android SDK configured in gmsaas: $sdk/platform-tools/adb" || fail "SDK adb: logged"
  rm -f "$FAKE/sdk_adb.log"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_SDK_PATH=~/.sdk")
  fan start --count 1
  rc_is 0 || fail "SDK path with ~: exit 0 (got $RC)"
  [ -s "$FAKE/sdk_adb.log" ] || fail "SDK path with ~: expanded to HOME"
  rm -f "$FAKE/sdk_adb.log"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A")
  fan start --count 1
  rc_is 0 || fail "no SDK path: exit 0 (got $RC)"
  [ ! -e "$FAKE/sdk_adb.log" ] || fail "no SDK path: the SDK adb was not used"
  err_has "using adb from PATH: $FAKES/adb" || fail "no SDK path: adb from PATH logged"
  [ "$(count_calls ' config get android-sdk-path')" -eq 3 ] || fail "one config get per start"
}

# An internal error after the first start call: everything is stopped, exit 5.
t_crash_after_first_start() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_LOCK_AFTER_LISTS=2:$PROJ/.genymotion/runs")
  fan start --count 2
  chmod 755 "$PROJ/.genymotion/runs" 2>/dev/null
  rc_is 5 || fail "exit 5 (got $RC)"
  fake_none || fail "fake has no instance left (got $(fake_count))"
  jt '.error | test("internal error")' || fail "error says internal error"
}

t_timeout_stopped_when_min_met() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_BEHAVIOUR_2=slow")
  fan start --count 2
  rc_is 0 || fail "exit 0 (got $RC)"
  jt '.instances[1].status == "TIMEOUT"' || fail "index 2 TIMEOUT"
  [ "$(fake_count)" -eq 1 ] || fail "exactly one instance left (got $(fake_count))"
}

t_second_signal_ignored_during_teardown() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "GENYMOTION_POLL_INTERVAL=30" "GENYMOTION_STOP_POLL_INTERVAL=1"
        "FAKE_GMSAAS_BEHAVIOUR_1=slow" "FAKE_GMSAAS_BEHAVIOUR_2=slow"
        "FAKE_GMSAAS_STOP_LISTS_1=4" "FAKE_GMSAAS_STOP_LISTS_2=4")
  bg_start start --count 2
  wait_sleeping_child "$BG_PID" || fail "the script was waiting between two polls"
  kill -TERM "$BG_PID"
  wait_calls_at_least ' instances stop ' 2 || fail "teardown started"
  sleep 0.5
  kill -TERM "$BG_PID" 2>/dev/null
  bg_wait
  rc_is 143 || fail "exit 143 (got $RC)"
  [ "$(stop_calls)" -eq 2 ] || fail "one stop call per instance (got $(stop_calls))"
  fake_none || fail "fake has no instance left (got $(fake_count))"
}

t_no_auth_and_usage_errors() {
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_NO_AUTH=1")
  fan start --count 1
  rc_is 3 || fail "no authentication (gmsaas exit 6): exit 3 (got $RC)"
  err_has "No authentication set" || fail "no authentication: message relayed"
  ENVX=("GENYMOTION_SAAS_RECIPE=$RECIPE_A" "FAKE_GMSAAS_LIST_USAGE_ERROR=1")
  fan start --count 1
  rc_is 3 || fail "usage error (plain text): exit 3 (got $RC)"
  err_has "Error: No such option: --fake-broken" || fail "usage error: last line relayed"
  [ "$(start_calls)" -eq 0 ] || fail "zero start calls"
}

# --- Runner --------------------------------------------------------------------
pass=0 failed=0 skipped=0
failed_names=()
selected() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }
# end_test STATUS: the subshell exit code (77 = skipped variant, else the assertion result).
end_test() { [ "$1" -eq 77 ] && exit 77; exit "$T_FAILED"; }
report() { # name status
  case "$2" in
    0) echo "PASS $1"; pass=$((pass + 1)) ;;
    77) echo "SKIP $1"; skipped=$((skipped + 1)) ;;
    *) echo "FAIL $1"; failed=$((failed + 1)); failed_names+=("$1") ;;
  esac
}

# Each test runs in a subshell, in its own project directory.
if selected t_normal_start_of_three; then (new_project; T_FAILED=0; t_normal_start_of_three; end_test $?); report t_normal_start_of_three $?; fi
if selected t_partial_boot_failure; then (new_project; T_FAILED=0; t_partial_boot_failure; end_test $?); report t_partial_boot_failure $?; fi
if selected t_interrupt_sigterm; then (new_project; T_FAILED=0; t_interrupt_sigterm; end_test $?); report t_interrupt_sigterm $?; fi
if selected t_interrupt_sighup; then (new_project; T_FAILED=0; t_interrupt_sighup; end_test $?); report t_interrupt_sighup $?; fi
if selected t_interrupt_sigint; then (new_project; T_FAILED=0; t_interrupt_sigint; end_test $?); report t_interrupt_sigint $?; fi
if selected t_interrupt_before_uuid_recorded; then (new_project; T_FAILED=0; t_interrupt_before_uuid_recorded; end_test $?); report t_interrupt_before_uuid_recorded $?; fi
if selected t_sigkill_then_stop_by_logged_run_id; then (new_project; T_FAILED=0; t_sigkill_then_stop_by_logged_run_id; end_test $?); report t_sigkill_then_stop_by_logged_run_id $?; fi
if selected t_sigkill_during_start_call_then_stop; then (new_project; T_FAILED=0; t_sigkill_during_start_call_then_stop; end_test $?); report t_sigkill_during_start_call_then_stop $?; fi
if selected t_stop_twice; then (new_project; T_FAILED=0; t_stop_twice; end_test $?); report t_stop_twice $?; fi
if selected t_count_above_cap; then (new_project; T_FAILED=0; t_count_above_cap; end_test $?); report t_count_above_cap $?; fi
if selected t_missing_config_noninteractive; then (new_project; T_FAILED=0; t_missing_config_noninteractive; end_test $?); report t_missing_config_noninteractive $?; fi
if selected t_below_min; then (new_project; T_FAILED=0; t_below_min; end_test $?); report t_below_min $?; fi
if selected t_all_slow_timeout; then (new_project; T_FAILED=0; t_all_slow_timeout; end_test $?); report t_all_slow_timeout $?; fi
if selected t_all_failed_exit5; then (new_project; T_FAILED=0; t_all_failed_exit5; end_test $?); report t_all_failed_exit5 $?; fi
if selected t_start_call_failure_quota; then (new_project; T_FAILED=0; t_start_call_failure_quota; end_test $?); report t_start_call_failure_quota $?; fi
if selected t_start_failure_but_created_is_stopped; then (new_project; T_FAILED=0; t_start_failure_but_created_is_stopped; end_test $?); report t_start_failure_but_created_is_stopped $?; fi
if selected t_all_start_failed_exit3; then (new_project; T_FAILED=0; t_all_start_failed_exit3; end_test $?); report t_all_start_failed_exit3 $?; fi
if selected t_auth_failure; then (new_project; T_FAILED=0; t_auth_failure; end_test $?); report t_auth_failure $?; fi
if selected t_precedence_recipe; then (new_project; T_FAILED=0; t_precedence_recipe; end_test $?); report t_precedence_recipe $?; fi
if selected t_precedence_prefix; then (new_project; T_FAILED=0; t_precedence_prefix; end_test $?); report t_precedence_prefix $?; fi
if selected t_precedence_duration; then (new_project; T_FAILED=0; t_precedence_duration; end_test $?); report t_precedence_duration $?; fi
if selected t_precedence_base_port; then (new_project; T_FAILED=0; t_precedence_base_port; end_test $?); report t_precedence_base_port $?; fi
if selected t_named_recipe; then (new_project; T_FAILED=0; t_named_recipe; end_test $?); report t_named_recipe $?; fi
if selected t_duration_bounds; then (new_project; T_FAILED=0; t_duration_bounds; end_test $?); report t_duration_bounds $?; fi
if selected t_platform; then (new_project; T_FAILED=0; t_platform; end_test $?); report t_platform $?; fi
if selected t_busy_port_skipped; then (new_project; T_FAILED=0; t_busy_port_skipped; end_test $?); report t_busy_port_skipped $?; fi
if selected t_busy_ports_bounded; then (new_project; T_FAILED=0; t_busy_ports_bounded; end_test $?); report t_busy_ports_bounded $?; fi
if selected t_adb_failed_stopped; then (new_project; T_FAILED=0; t_adb_failed_stopped; end_test $?); report t_adb_failed_stopped $?; fi
if selected t_adb_start_when_empty; then (new_project; T_FAILED=0; t_adb_start_when_empty; end_test $?); report t_adb_start_when_empty $?; fi
if selected t_stop_all_mine; then (new_project; T_FAILED=0; t_stop_all_mine; end_test $?); report t_stop_all_mine $?; fi
if selected t_status_output; then (new_project; T_FAILED=0; t_status_output; end_test $?); report t_status_output $?; fi
if selected t_no_recorded_run; then (new_project; T_FAILED=0; t_no_recorded_run; end_test $?); report t_no_recorded_run $?; fi
if selected t_stop_unverified_exit6; then (new_project; T_FAILED=0; t_stop_unverified_exit6; end_test $?); report t_stop_unverified_exit6 $?; fi
if selected t_start_unverified_exit6; then (new_project; T_FAILED=0; t_start_unverified_exit6; end_test $?); report t_start_unverified_exit6 $?; fi
if selected t_token_never_leaks; then (new_project; T_FAILED=0; t_token_never_leaks; end_test $?); report t_token_never_leaks $?; fi
if selected t_help; then (new_project; T_FAILED=0; t_help; end_test $?); report t_help $?; fi
if selected t_json_on_error_paths; then (new_project; T_FAILED=0; t_json_on_error_paths; end_test $?); report t_json_on_error_paths $?; fi
if selected t_missing_binaries; then (new_project; T_FAILED=0; t_missing_binaries; end_test $?); report t_missing_binaries $?; fi
if selected t_defaults_match_contract; then (new_project; T_FAILED=0; t_defaults_match_contract; end_test $?); report t_defaults_match_contract $?; fi
if selected t_pipe_closed_tears_down; then (new_project; T_FAILED=0; t_pipe_closed_tears_down; end_test $?); report t_pipe_closed_tears_down $?; fi
if selected t_stdout_closed_tears_down; then (new_project; T_FAILED=0; t_stdout_closed_tears_down; end_test $?); report t_stdout_closed_tears_down $?; fi
if selected t_corrupt_state_file; then (new_project; T_FAILED=0; t_corrupt_state_file; end_test $?); report t_corrupt_state_file $?; fi
if selected t_stop_during_start; then (new_project; T_FAILED=0; t_stop_during_start; end_test $?); report t_stop_during_start $?; fi
if selected t_stop_call_retried; then (new_project; T_FAILED=0; t_stop_call_retried; end_test $?); report t_stop_call_retried $?; fi
if selected t_interrupt_during_slow_call; then (new_project; T_FAILED=0; t_interrupt_during_slow_call; end_test $?); report t_interrupt_during_slow_call $?; fi
if selected t_interrupt_inflight_start_fails; then (new_project; T_FAILED=0; t_interrupt_inflight_start_fails; end_test $?); report t_interrupt_inflight_start_fails $?; fi
if selected t_interrupt_inflight_start_server_side; then (new_project; T_FAILED=0; t_interrupt_inflight_start_server_side; end_test $?); report t_interrupt_inflight_start_server_side $?; fi
if selected t_interrupt_during_stop; then (new_project; T_FAILED=0; t_interrupt_during_stop; end_test $?); report t_interrupt_during_stop $?; fi
if selected t_late_instance_warned; then (new_project; T_FAILED=0; t_late_instance_warned; end_test $?); report t_late_instance_warned $?; fi
if selected t_stale_pid_unrelated_process; then (new_project; T_FAILED=0; t_stale_pid_unrelated_process; end_test $?); report t_stale_pid_unrelated_process $?; fi
if selected t_readonly_project_dir; then (new_project; T_FAILED=0; t_readonly_project_dir; end_test $?); report t_readonly_project_dir $?; fi
if selected t_late_instance_swept; then (new_project; T_FAILED=0; t_late_instance_swept; end_test $?); report t_late_instance_swept $?; fi
if selected t_adbconnect_exit13_already_connected; then (new_project; T_FAILED=0; t_adbconnect_exit13_already_connected; end_test $?); report t_adbconnect_exit13_already_connected $?; fi
if selected t_adbconnect_exit12_timeout; then (new_project; T_FAILED=0; t_adbconnect_exit12_timeout; end_test $?); report t_adbconnect_exit12_timeout $?; fi
if selected t_adb_resolution; then (new_project; T_FAILED=0; t_adb_resolution; end_test $?); report t_adb_resolution $?; fi
if selected t_crash_after_first_start; then (new_project; T_FAILED=0; t_crash_after_first_start; end_test $?); report t_crash_after_first_start $?; fi
if selected t_timeout_stopped_when_min_met; then (new_project; T_FAILED=0; t_timeout_stopped_when_min_met; end_test $?); report t_timeout_stopped_when_min_met $?; fi
if selected t_second_signal_ignored_during_teardown; then (new_project; T_FAILED=0; t_second_signal_ignored_during_teardown; end_test $?); report t_second_signal_ignored_during_teardown $?; fi
if selected t_no_auth_and_usage_errors; then (new_project; T_FAILED=0; t_no_auth_and_usage_errors; end_test $?); report t_no_auth_and_usage_errors $?; fi

echo "----"
echo "$pass passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ] || { echo "failed: ${failed_names[*]}"; exit 1; }
exit 0
