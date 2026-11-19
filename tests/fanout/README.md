# Tests for `scripts/fanout.sh`

Offline tests. They never call Genymotion SaaS and never start a real device.

## Run

```bash
tests/fanout/run-tests.sh            # every test
tests/fanout/run-tests.sh interrupt  # only the tests whose name contains "interrupt"
```

Requirements: Bash 4.4 or later, `jq`, `ps` and the usual POSIX tools. No test framework to install.

The runner prints one `PASS`, `FAIL` or `SKIP` line per test, then a summary. It exits 1 when a test fails. A full run takes about a minute: some tests wait on purpose for signals and slow calls.

The suite has been run on Linux only.

## How it stays offline

- `fakes/gmsaas` and `fakes/adb` stand in for the real tools. The fake `gmsaas` keeps its instances in a temporary directory and logs every call.
- The runner sets `PATH` to `tests/fanout/fakes`, then a directory holding a link to the bash that runs the suite, then `/usr/bin:/bin`. It aborts before the first test unless `gmsaas` and `adb` both resolve to the fakes.
- Each test runs the script by its path, from its own temporary project directory, with a clean environment (`env -i`). Your own `GENYMOTION_*` variables and API token are not passed to the script.
- Poll intervals are set to 0 in most tests, so they run in a fraction of a second.

## Fake knobs

The fake `gmsaas` is driven by environment variables. The header of `fakes/gmsaas` describes each one.

- `FAKE_GMSAAS_DIR`: the fake's state directory (required).
- `FAKE_GMSAAS_AUTH_FAIL=1`: every call fails as not authenticated (token rejected, exit 3).
- `FAKE_GMSAAS_NO_AUTH=1`: every call fails as not configured (no authentication set, exit 6).
- `FAKE_GMSAAS_LIST_USAGE_ERROR=1`: `instances list` fails with a plain-text usage error (exit 2).
- `FAKE_GMSAAS_BEHAVIOUR_<index>`: `normal`, `slow`, `fail`, `vanish`, `startfail`, `startfail_created`, `adboffline`, `stuckstop`.
- `FAKE_GMSAAS_START_DELAY_<index>`: seconds the start call waits after creating the instance.
- `FAKE_GMSAAS_CREATE_DELAY_<index>`: seconds before the "server" creates the instance, even if the client is killed.
- `FAKE_GMSAAS_HIDE_LISTS_<index>`: number of list calls that do not show a new instance yet.
- `FAKE_GMSAAS_STOP_FAIL_ONCE_<index>=1`: the first stop call on the instance fails (exit 4).
- `FAKE_GMSAAS_STOP_LISTS_<index>`: number of list calls that still show a stopped instance as `STOPPING` (default 1).
- `FAKE_GMSAAS_BUSY_PORTS`: ports where `adbconnect` reports a busy port (exit 11).
- `FAKE_GMSAAS_ADBCONNECT_DELAY`: seconds `adbconnect` waits before answering.
- `FAKE_GMSAAS_ADB_ALREADY_<index>=<port>`: the instance is already connected on that port (exit 13 on any other).
- `FAKE_GMSAAS_ADB_TIMEOUT_<index>=1`: `adbconnect` times out (exit 12).
- `FAKE_GMSAAS_SDK_PATH`: the value of `config get android-sdk-path` (default: empty).
- `FAKE_GMSAAS_LOCK_AFTER_LISTS=<n>:<dir>`: after the n-th list call, make `<dir>` read-only.
- `FAKE_GMSAAS_STDERR_PROBE=<file>`: on each start call, record whether `<file>` already holds the run id line.
- `FAKE_ADB_NEEDS_START=1` (fake `adb`): `adb devices` lists nothing until `gmsaas adb start` ran.

## Skipped test

`t_interrupt_sigint` needs `env --default-signal` (GNU coreutils 8.31 or later). Without it the test prints `SKIP` and says so; a skip is not a pass.
