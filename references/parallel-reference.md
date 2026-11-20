# Genymotion — Several Devices in Parallel

How to start several Genymotion devices for one task, hand them to a test runner, and stop them all.

```
decide N ──▶ start N (--no-wait, --max-run-duration) ──▶ poll all until ONLINE / failed / timed out
                                                                    │
     stop every instance, verify none is left  ◀── run the tests ◀── connect ADB on distinct ports
     (mandatory, also after a failure)                               and print UUID → serial
```

> **Teardown is mandatory.** SaaS instances are billed while they run. Stop every instance of the run at the end, also when the tests fail or the agent hits an error, and verify that none is still running.

- Use **`scripts/fanout.sh`** when you can run shell commands. It does every step below and cleans up after itself.
- Use the **raw `gmsaas` commands** when the client cannot run scripts.
- For **Genymotion Desktop**, see the [last section](#genymotion-desktop).

---

## With `scripts/fanout.sh`

### Requirements

- Bash 4.4 or later, `gmsaas` (authenticated, Android SDK path set) and `jq` in `PATH`.
- `adb`: the script uses the one of the Android SDK configured in `gmsaas` (`<android-sdk-path>/platform-tools/adb`), and the one in `PATH` when that file does not exist. The result of `start` gives its path in `adb`. Use that same `adb` for your own commands: an `adb` of another version restarts the ADB server and drops the connections of every run on the machine.
- Run every command **from the project directory**, and call the script by its path: it is in the `scripts/` directory next to the skill's `SKILL.md` (for example `.claude/skills/genymotion/scripts/fanout.sh`). Do not `cd` into the skill directory: the script reads `.genymotion.json` and keeps its run records under the directory it is called from.
- `start` can run for a long time: up to 10 polls 30 seconds apart, then up to a minute of ADB connection for each instance, then the stop of the instances that failed. Give the command a timeout of at least 10 minutes plus 2 minutes per instance (20 minutes for 5 instances), or run it in the background. Give `stop` a timeout of at least 5 minutes, and 10 minutes when a `start` of the same run may still be running: `stop` first waits for it, up to 4 minutes.

### Commands

```bash
fanout.sh start [--count N] [--recipe <uuid|name>] [--prefix <p>] \
                [--max-run-duration <minutes>] [--base-port <port>] [--min <M>]
fanout.sh status [--run <run-id>]
fanout.sh stop   [--run <run-id> | --all-mine]
fanout.sh --help
```

| Command | What it does |
|---|---|
| `start` | Starts `N` SaaS instances (default 1), waits until each is `ONLINE`, connects ADB on distinct ports, checks every serial with `adb devices`, prints the result. |
| `status` | Prints the live state and the serial of each instance of a run. Without `--run`: the most recent run. |
| `stop` | Stops every instance of a run, then verifies that none is still running. It sends its stop calls from the run record even when `gmsaas` cannot list the instances; it then exits 6, because nothing can be verified. It exits 0 only when its lookup of the run's instances by name ran on a list that succeeded. When a `start` was cut during a start call, it waits up to 40 seconds for that instance to appear. Without a flag: the most recent run recorded in this directory. With `--run <run-id>` and no record of that run in this directory, it finds the instances of the run by their names in the account; it cannot reach a `start` of that run that is still running in its own directory, and says so. |
| `stop --all-mine` | Stops every run recorded here with the configured prefix, and every running instance named `<prefix>-<run-id>-<index>` for that prefix, then verifies. Runs of another prefix are left alone. |

Always pass `--run <run_id>` to `stop`, with the `run_id` printed by `start`. Running `stop` again on a stopped run is safe and exits 0, from the directory that holds the record of the run and when `gmsaas` can list the instances.

### Settings

A flag overrides the environment variable, which overrides `.genymotion.json`, which overrides the default. All settings are in `references/configuration.md`.

| Flag | Environment variable | `.genymotion.json` key | Default |
|---|---|---|---|
| `--recipe` | `GENYMOTION_SAAS_RECIPE` | `saasRecipe` | none (required) |
| `--prefix` | `GENYMOTION_INSTANCE_PREFIX` | `instancePrefix` | `agent` |
| `--max-run-duration` | `GENYMOTION_MAX_RUN_DURATION` | `maxRunDuration` | `60` (minutes) |
| `--base-port` | `GENYMOTION_ADB_BASE_PORT` | `adbBasePort` | `15555` |
| — | `GENYMOTION_MAX_INSTANCES` | `maxInstances` | `5` |
| — | `GENYMOTION_PLATFORM` | `platform` | — |

- `--count` above `GENYMOTION_MAX_INSTANCES` is refused; nothing is started.
- `--min` is the smallest number of usable instances that makes the run worth keeping. Default 1.
- `start` refuses to run when the platform resolves to `desktop`. For an explicit SaaS request in such a project, set `GENYMOTION_PLATFORM=saas` on the call.
- The script never asks a question. A missing recipe is a configuration error in every mode.

Three environment variables tune the waiting time. They exist mainly for the tests:

- `GENYMOTION_POLL_INTERVAL`: seconds between two boot polls. Default 30. The script polls 10 times at most, as in `SKILL.md`.
- `GENYMOTION_STOP_POLL_INTERVAL`: seconds between two stop checks. Default 10. The script checks 12 times at most.
- `GENYMOTION_CALL_TIMEOUT`: time limit of one `gmsaas` call, in seconds, 1 to 3600. Default: 60, and 90 for `instances stop` and `instances adbconnect`.

### Output

Standard output carries exactly one JSON object. Progress and errors go to standard error.

```json
{
  "run_id": "20261118171600-a3f19c02",
  "adb": "/home/me/Android/Sdk/platform-tools/adb",
  "instances": [
    {"name": "agent-20261118171600-a3f19c02-1", "uuid": "<instance_uuid>", "serial": "localhost:15555", "status": "ONLINE"},
    {"name": "agent-20261118171600-a3f19c02-2", "uuid": "<instance_uuid>", "serial": "localhost:15556", "status": "ONLINE"},
    {"name": "agent-20261118171600-a3f19c02-3", "uuid": "<instance_uuid>", "serial": null, "status": "BOOT_FAILED"}
  ]
}
```

- `run_id` is `null` when no run applies (configuration error, nothing recorded, `--all-mine`).
- `adb` is in the output of `start` only: the path of the `adb` the script used, or `null` when it did not get that far.
- `uuid` and `serial` are `null` when the instance has none.
- An `error` string is added when the exit code is not 0.

| `status` | Meaning |
|---|---|
| `ONLINE` | Running, ADB connected, serial confirmed by `adb devices`. Usable. |
| `START_FAILED` | `gmsaas instances start` failed for this instance (for example, account quota reached). |
| `BOOT_FAILED` | The instance left the starting states without reaching `ONLINE`, or was listed and then disappeared. |
| `TIMEOUT` | Still starting, or still not listed, after the last poll. |
| `ADB_FAILED` | `ONLINE`, but ADB could not be connected or the serial did not show as `device`. |
| `STOPPED` | Stopped and verified: `gmsaas instances list` no longer shows the instance, and `gmsaas instances get` reports it deleted or not found. Neither the answer to a stop call nor one list alone proves it. An instance that the run record already marks as verified is not checked again. An instance that failed keeps its failure status after it is stopped. |
| `UNVERIFIED` | In `status` and `stop` output only: no list succeeded, or `gmsaas` does not list the instance and could not say whether it still exists. |
| a `gmsaas` state | In `status` and `stop` output only: the live state of an instance that is neither `ONLINE` nor stopped (`BOOTING`, `STOPPING`…). An instance that `gmsaas` still lists as `STOPPED` is shown as `STOPPING`: here `STOPPED` always means verified. |

After `start` returns, every instance that is not `ONLINE` has already been stopped: `start` sends a stop for every instance it created, listed or not. One case is left: a start call that failed can still have created an instance, with a UUID the script never received, that is listed later. `start` says so on standard error, and the final `stop --run` stops it.

### Exit codes

| Code | Name | Meaning |
|---|---|---|
| 0 | success | `start`: at least `--min` instances are usable (read each `status`: some may have failed). `stop`: verified, nothing is running. `status`: printed. |
| 1 | partial | `start`: some instances came up, but fewer than `--min`. Everything was stopped. |
| 2 | configuration | Bad flag, missing or invalid setting, count above the cap, `jq` / `adb` / `gmsaas` not found, a project directory that cannot be written, (`status`) a run file that cannot be read, or (`stop --run`, `status --run`) a run id with no record here and no instance in the account. Nothing was started. |
| 3 | gmsaas | `gmsaas` failed: not authenticated, Android SDK path not set, API or network error, or no instance could be created. Also for `status`, and for `stop` when it has no run record to work from, when the instances cannot be listed. |
| 4 | timeout | `start`: no instance was usable and at least one was still starting after the last poll. Everything was stopped. |
| 5 | failed | `start`: no instance was usable (boot or ADB failures), the stop of a failed instance could not be verified at first, a `stop` was requested for this run, the result could not be printed, or the script hit an internal error. Everything was stopped, healthy instances included. |
| 6 | stop incomplete | At least one instance is not verified stopped, or the instances could not be listed. Run `stop` again, then check https://cloud.geny.io/instances. |
| 129, 130, 143 | interrupted | `start` received a hang-up, Ctrl-C or a termination signal. It stopped everything it had started before exiting. |

### What `start` guarantees

- Every instance is named `<prefix>-<run-id>-<index>` and started with `--no-wait` and `--max-run-duration`.
- The run id is a UTC timestamp to the second and eight random hexadecimal digits, for example `20261118171600-a3f19c02`. Run ids sort by start time, to the second.
- The run is recorded in `.genymotion/runs/<run-id>.json` (UUIDs, names, serials) as soon as each instance exists, so `stop` works from a new shell. Each name is recorded before its start call: `stop` and `status` also find an instance whose UUID was not recorded yet, by its exact name.
- Failed instances are stopped and reported; healthy ones are kept, as long as there are at least `--min` of them.
- An interrupted or crashed `start` stops everything it started. So does a `start` whose output pipe is closed, and a `start` whose run receives a `stop` from another shell: that `start` exits with code 5, and the `stop` waits for it.
- A non-zero exit code from `start` means that every instance it created was stopped, except with code 6. The final `stop --run <run_id>` is still required: it also stops an instance whose start call failed and that was listed too late.
- An instance that `gmsaas` does not list yet is not a failed one: `start` waits for it until the last poll.
- A busy ADB port is skipped: the script tries the next port.
- Every `gmsaas` and `adb` call has a time limit: a call that hangs is ended and counts as failed. The timeouts given above are for a `gmsaas` that answers; when its calls hang one after the other, a command takes much longer before it reports the failure (a stop call that hangs in every round costs about 20 minutes per instance). When your own timeout ends a `stop` first, run `stop --run <run-id>` again once `gmsaas` answers.
- The API token is never printed or logged.

`start` writes its run id on standard error before it starts any instance. If `start` ends without printing its JSON (killed, tool timeout), run `fanout.sh stop --run <run-id>` at once with that id. Use `stop` without a flag only when no other run is active in this directory: it stops the most recent run, which may belong to another agent. A process killed with `SIGKILL` cannot clean up by itself. `--max-run-duration` then limits the cost, but its countdown starts when the instance has booted, so it does not cover an instance that never boots: always run `stop`.

A `start` launched in the background by a non-interactive shell ignores Ctrl-C (`SIGINT`). Interrupt it with `SIGTERM`, or with `fanout.sh stop --run <run-id>`.

### Example

```bash
FANOUT=.claude/skills/genymotion/scripts/fanout.sh    # adapt to where the skill is installed

# 1. Start three devices and keep the result
RESULT="$("$FANOUT" start --count 3 --recipe phone)"
RUN_ID="$(jq -r '.run_id' <<<"$RESULT")"

# 2. Run the tests on every usable device
ADB="$(jq -r '.adb' <<<"$RESULT")"      # the adb the script used
for SERIAL in $(jq -r '.instances[] | select(.status == "ONLINE") | .serial' <<<"$RESULT"); do
  "$ADB" -s "$SERIAL" install -r app.apk
done

# 3. Always stop the run, also when a step above failed
"$FANOUT" stop --run "$RUN_ID"
```

`--all-mine` matches the names `<prefix>-<run-id>-<index>` across the whole account, whoever started them. On a shared account, give each user or pipeline its own `GENYMOTION_INSTANCE_PREFIX`.

The script writes its own `.gitignore` inside `.genymotion/runs/`, so the run records stay out of git. Adding `.genymotion/runs/` to the project's `.gitignore` makes that visible. `start` deletes the records that are more than 30 days old, when `gmsaas` lists no instance of their run. An instance cannot run for more than 28800 minutes (20 days).

---

## With raw `gmsaas` commands

Follow these steps when you cannot run the script. The JSON field names below are those of `gmsaas --format compactjson`.

### 1. Decide N

- N is the requested count, capped by `GENYMOTION_MAX_INSTANCES` (default 5). Refuse a larger request and say why.
- Resolve the recipe and the other settings with `references/configuration.md`.
- **Account quota lower than N**: a start call beyond the quota fails. Do not retry it. Continue with the instances that started and report "requested N, started M".

### 2. Start N instances with unique names

Pick a run id that no other run can have: a timestamp and a few random characters. Name each instance `<prefix>-<run-id>-<index>`, with the configured prefix (default `agent`). Start each one with `--no-wait` so the boots overlap. Always set `--max-run-duration` to the configured number of minutes (default 60).

```bash
# Linux / macOS
RUN_ID="$(date -u +%Y%m%d%H%M%S)-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
```

```powershell
# Windows (PowerShell)
$RUN_ID = "{0}-{1:x8}" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'), (Get-Random -Maximum 2147483647)
```

```bash
gmsaas --format compactjson instances start <recipe_uuid> "<prefix>-<run-id>-1" --no-wait --max-run-duration <minutes>
gmsaas --format compactjson instances start <recipe_uuid> "<prefix>-<run-id>-2" --no-wait --max-run-duration <minutes>
gmsaas --format compactjson instances start <recipe_uuid> "<prefix>-<run-id>-3" --no-wait --max-run-duration <minutes>
```

Each call prints the new instance. Write the run id, and each `instance.uuid` and `instance.name`, in your notes or your reply as soon as they are printed: a shell variable does not survive between two tool calls, and you need every UUID for the teardown.

### 3. Poll all instances together

```bash
gmsaas --format compactjson instances list
# → instances[]: uuid, name, state, adb_serial
```

Repeat up to 10 times, 30 seconds apart (the limits of `SKILL.md`), and read the `state` of each instance of the run:

| `state` | Action |
|---|---|
| `ONLINE` | Ready. |
| `CREATING`, `STARTING`, `OFFLINE`, `BOOTING`, `UNKNOWN` | Still starting. Wait. |
| not listed yet | Still starting. Wait. |
| anything else, or the instance was listed and is no longer listed | Failed. |

An instance that is still starting, or still not listed, after the 10th poll has timed out. With `--no-wait`, an instance goes through several starting states before `BOOTING`; none of them is an error.

### 4. Connect ADB on distinct ports

Give each instance its own local port, counting up from a base port.

```bash
gmsaas --format compactjson instances adbconnect <instance_uuid_1> --adb-serial-port 15555
gmsaas --format compactjson instances adbconnect <instance_uuid_2> --adb-serial-port 15556
gmsaas --format compactjson instances adbconnect <instance_uuid_3> --adb-serial-port 15557
# → instance.adb_serial, for example "localhost:15555"

adb devices
# Expected: every recorded serial is listed in state "device"
```

- Record the serial that each call prints (`instance.adb_serial`), not the port you asked for.
- **Why 15555**: it is above the ports ADB scans for local emulators (5554–5585), away from the ADB server port (5037), and below the ranges the operating systems use for outgoing connections (32768 and up on Linux, 49152 and up on macOS and Windows).
- If a port is busy (`gmsaas` exit code 11), use the next one. Exit code 13 means the instance is already connected on another port: read its serial with `gmsaas --format compactjson instances get <instance_uuid>`.
- If `adb devices` is empty, run `gmsaas adb start` and check again.

### 5. Report the mapping

Give the test runner a clear table, built from the recorded serials:

```
<prefix>-<run-id>-1   <instance_uuid_1>   localhost:15555
<prefix>-<run-id>-2   <instance_uuid_2>   localhost:15556
<prefix>-<run-id>-3   <instance_uuid_3>   localhost:15557
```

Target one device by its serial:

```bash
adb -s localhost:15556 install -r app.apk     # one command
export ANDROID_SERIAL=localhost:15556         # every adb command of this shell
```

### 6. Partial failure

- Continue with the healthy instances when that is still useful for the task.
- Stop the failed and timed-out instances at once (step 7), and report which ones failed.
- If no instance is usable, stop everything and report the failure.

### 7. Teardown (mandatory)

Stop every instance of the run, by recorded UUID, whether `gmsaas instances list` shows it or not. If a UUID was lost, find the instance in `gmsaas instances list` by the full run prefix `<prefix>-<run-id>-`. Never match on the bare prefix: it also matches the instances of other runs.

```bash
gmsaas instances stop <instance_uuid_1>
gmsaas instances stop <instance_uuid_2>
gmsaas instances stop <instance_uuid_3>

gmsaas --format compactjson instances list
# Expected: no instance of the run is listed
```

- Do this also when the tests failed or an earlier step raised an error.
- An instance listed as `STOPPING`, `STOPPED`, `OFFLINE` or `DELETING` is on its way out: check again, up to 12 times, 10 seconds apart, until it is no longer listed.
- If an instance is listed in any other state, or is still listed after the last check, stop it again, then point the user to https://cloud.geny.io/instances.

---

## Genymotion Desktop

Desktop devices run on the local machine, so parallelism is limited by the host's RAM and CPU. Two or three devices is a reasonable ceiling on a developer laptop. For more, use Genymotion SaaS.

<!-- TODO: verify — simultaneous Desktop devices and any licence limit were not checked on a live Genymotion Desktop -->

```bash
# 1. Start each device (one device cannot run twice: clone it if you need a copy)
gmtool admin clone "Pixel 7 API 33" "Pixel 7 API 33 - 2"
gmtool admin start "Pixel 7 API 33"
gmtool admin start "Pixel 7 API 33 - 2"

# 2. Verify
gmtool admin list --running     # both devices listed
adb devices                     # one serial per device

# 3. Stop when done, then verify
gmtool admin stop "Pixel 7 API 33"
gmtool admin stop "Pixel 7 API 33 - 2"
gmtool admin list --running     # neither device listed
```

`gmtool admin stopall` stops every running Desktop device, including devices that are not part of the task. Prefer stopping by name.
