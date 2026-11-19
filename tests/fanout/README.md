# Tests for `scripts/fanout.sh`

Offline tests. They never call Genymotion SaaS and never start a real device.

## Run

```bash
tests/fanout/run-tests.sh            # every test
tests/fanout/run-tests.sh interrupt  # only the tests whose name contains "interrupt"
```

Requirements: Bash 4.4 or later, `jq`, `ps` and the usual POSIX tools. No test framework to install.

The runner prints one `PASS`, `FAIL` or `SKIP` line per test, then a summary. It exits 1 when a test fails. A full run takes about two minutes: some tests wait on purpose for signals and slow calls. `t_adb_devices_hang_bounded` alone takes about 20 seconds (the `adb devices` timeout of the script).

The suite has been run on Linux only.

## How it stays offline

- `fakes/gmsaas` and `fakes/adb` stand in for the real tools. The fake `gmsaas` keeps its instances in a temporary directory and logs every call.
- The runner sets `PATH` to `tests/fanout/fakes`, then a directory holding a link to the bash that runs the suite, then `/usr/bin:/bin`. It aborts before the first test unless `gmsaas` and `adb` both resolve to the fakes.
- Each test runs the script by its path, from its own temporary project directory, with a clean environment (`env -i`). Your own `GENYMOTION_*` variables and API token are not passed to the script.
- Poll intervals are set to 0 in most tests, so they run in a fraction of a second.
- The runner builds a temporary Android SDK whose `platform-tools/adb` is a link to the fake `adb`, and gives its path to the fake `gmsaas` (`FAKE_GMSAAS_SDK_PATH`). So, by default, the script uses the adb of the gmsaas Android SDK, as it does with a real configuration.

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
- `FAKE_GMSAAS_SDK_PATH`: the value of `config get android-sdk-path`. As gmsaas 1.16.0 does, `instances list|get|stop|adbconnect` and `adb start` fail with exit 6 unless `<path>/platform-tools/adb` is an executable file. The runner sets a valid path by default.
- `FAKE_GMSAAS_CONFIG_GET_FAIL=1`: `config get` fails (exit 6).
- `FAKE_GMSAAS_STOP_ERROR_CODE_<index>=<n>`: every stop call on the instance fails with exit `<n>`.
- `FAKE_GMSAAS_STOP_STATE_<index>=<state>`: once stopped, the instance is listed in that state (default `STOPPING`).
- `FAKE_GMSAAS_HIDE_STOPPED_<index>=1`: once stopped, the instance is not listed while it stops; `instances get` still shows it, then answers 404.
- `FAKE_GMSAAS_LIST_FAIL_AFTER=<n>`: every list call after the n-th fails with an API error 502 (exit 4).
- `FAKE_GMSAAS_STOP_UNAVAILABLE=1`, `FAKE_GMSAAS_GET_UNAVAILABLE=1`: every stop or get call fails with an API error 503 (exit 4).
- `FAKE_GMSAAS_API_ERROR_MESSAGE=<message>`: the message of the three errors above, for example an HTML 404.
- `FAKE_GMSAAS_LIST_DROP_<index>=<n>`: the instance is left out of every list call from the n-th on, while it still exists; `FAKE_GMSAAS_LIST_DROP_ONCE_<index>=<n>`: out of the n-th list call only.
- `FAKE_GMSAAS_GET_DELETED_STATE=1`: `instances get` on an unknown or deleted UUID returns the state `DELETED` instead of a 404.
- As in gmsaas 1.16.0, `instances get` and `instances stop` on an unknown or deleted UUID fail with an API error 404 (exit 4). API errors use the message shape `API returns unexpected code: <status>. Error: <text>`.
- `FAKE_GMSAAS_LOCK_AFTER_LISTS=<n>:<dir>`: after the n-th list call, make `<dir>` read-only.
- `FAKE_GMSAAS_STDERR_PROBE=<file>`: on each start call, record whether `<file>` already holds the run id line.
- `FAKE_ADB_NEEDS_START=1` (fake `adb`): `adb devices` lists nothing until `gmsaas adb start` ran.
- `FAKE_ADB_HANG=<s>` (fake `adb`): `adb devices` hangs `<s>` seconds; `FAKE_ADB_HANG_ONCE=<s>`: only the first one does.

## Skipped test

`t_interrupt_sigint` needs `env --default-signal` (GNU coreutils 8.31 or later). Without it the test prints `SKIP` and says so; a skip is not a pass.
