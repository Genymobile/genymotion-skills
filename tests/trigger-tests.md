# Genymotion Skill — Trigger Tests

## Should trigger

### Cloud (gmsaas)
- "Start a Genymotion Cloud instance"
- "Launch an Android device on the cloud with gmsaas"
- "List my running Genymotion instances"
- "Stop my Genymotion Cloud instance"
- "Install my APK on a Genymotion Cloud device"
- "Connect ADB to my Genymotion SaaS instance"
- "I need to run automated tests on Genymotion Cloud"

### Desktop (gmtool)
- "Start a local Genymotion device"
- "Launch an Android 13 emulator locally"
- "List my Genymotion Desktop devices"
- "Connect ADB to my local Genymotion device"
- "Install an APK on my local Genymotion emulator"

### Web Player
- "Embed my Genymotion instance in a web page"
- "Generate an HTML page to display my Genymotion device"
- "How do I use the Genymotion device web player?"

### CI/CD
- "Set up Genymotion in my GitHub Actions pipeline"
- "How do I run Android tests on Genymotion in CI?"

### French
- "Lance un device Android 13 en local"
- "Démarre une instance Genymotion Cloud"
- "Arrête mon instance Genymotion"
- "Démarre trois instances Genymotion Cloud en parallèle"

## Should trigger (project opted in)

These requests do not mention Genymotion. They trigger only when the project has opted in: its `CLAUDE.md` or `AGENTS.md` carries the `## Android devices` block of the README. For a `.genymotion.json` file alone, see "Not guaranteed".

- "Run the UI tests and confirm the fix works"
- "Check these user journeys for memory leaks"
- "I need three devices to test this"
- "Reproduce the crash on an Android 14 device"
- "Lance les tests UI et vérifie que le correctif fonctionne"
- "J'ai besoin de deux appareils Android pour tester cette fonctionnalité"

## Not guaranteed

- "Run the UI tests and confirm the fix works", with a `.genymotion.json` at the repository root and no `## Android devices` block. Once the agent has seen the file, it uses the skill for device needs. Before that, no trigger is expected.

## Should NOT trigger

In a project that has **not** opted in:

- "Run the UI tests and confirm the fix works" (no Genymotion mention, no opt-in)
- "I need three devices to test this" (no Genymotion mention, no opt-in)
- "How do I write an Android app?"
- "What is the best Android emulator?" (generic, no Genymotion mention)
- "How do I use ADB?" (no Genymotion mention)
- "Help me set up Docker"
- "How do I run Espresso tests?" (no Genymotion mention)
- "What is the best mobile testing framework?"

Three kinds of request:

- An explicit request to manage an Android virtual device or emulator, or any mention of Genymotion, `gmsaas` or `gmtool`, triggers with or without opt-in ("Should trigger").
- A task that only needs a device as a means, like the first two cases above, triggers only in an opted-in project ("Should trigger (project opted in)").
- A generic Android development question, like the other cases above, never triggers, opted in or not.

In an opted-in project:

- "How do I use ADB?" (a question; no device is needed)

## Functional Test Cases

### Test 1 — Cloud: start instance + install APK
**User says**: "Start a Pixel 8 Pro on Genymotion Cloud and install my app.apk"

Expected behavior:
1. Platform detected: Cloud
2. `gmsaas` availability checked
3. `gmsaas recipes list` executed — user asked to pick one (interactive mode, no recipe configured)
4. `gmsaas instances start <recipe_uuid> <name> --max-run-duration <minutes>` executed (default 60)
5. State polled until ONLINE (up to 10 × 30s); `CREATING`, `STARTING`, `OFFLINE`, `BOOTING` and `UNKNOWN` mean "still starting"
6. `gmsaas instances adbconnect <instance_uuid>` executed
7. `adb devices` verified — instance appears
8. `adb install app.apk` executed
9. User reminded to stop the instance when done

### Test 2 — Desktop: start device
**User says**: "Launch an Android 13 device locally"

Expected behavior:
1. Platform detected: Local
2. `gmtool` availability checked
3. `gmtool admin list` executed — user asked to pick a device
4. `gmtool admin start <device>` executed
5. `gmtool admin list --running` verified — device appears
6. ADB auto-connected (no manual adbconnect needed)
7. Verified state reported to user

### Test 3 — Web Player: generate HTML page
**User says**: "Embed my Genymotion Cloud instance in a web page"

Expected behavior:
1. Template `templates/device-web-player.html` offered
2. Security notice shown: retrieve WebRTC address and access token in own terminal
3. curl commands provided (not executed) for webrtc_url and access token
4. User instructed to edit WEBRTC_ADDRESS and ACCESS_TOKEN in the HTML file
5. Local server command provided (npx serve / python3 -m http.server)

### Test 4 — CI/CD setup
**User says**: "Set up Genymotion in my GitHub Actions pipeline"

Expected behavior:
1. Platform detected: Cloud (CI/CD is SaaS only)
2. `references/cicd-reference.md` read
3. User pointed to official GitHub Actions plugin
4. GENYMOTION_API_TOKEN secret storage advised
5. `--max-run-duration` (minutes) recommended
6. `if: always()` stop step recommended

### Test 5 — Several Cloud devices, then teardown
**User says**: "Start 5 Android 14 devices on Genymotion Cloud, run the tests on all of them, then shut everything down"

Expected behavior:
1. Platform detected: Cloud; `references/parallel-reference.md` read
2. Count 5 checked against the cap (`GENYMOTION_MAX_INSTANCES`, default 5); a larger count is refused and nothing is started
3. Android 14 recipe resolved from the configuration, or picked by the user in interactive mode
4. `fanout.sh start --count 5 --recipe <recipe>` run from the project root, by its path inside the skill directory
5. `run_id` kept from the JSON output; the tests are driven through the UUID → serial mapping, on the instances whose `status` is `ONLINE`
6. `fanout.sh stop --run <run_id>` run, also when the tests fail
7. Stop verified: exit code 0, no instance of the run listed by `gmsaas instances list`
8. Without shell scripts: the raw `gmsaas` steps of the reference (`--no-wait`, `--max-run-duration`, distinct `--adb-serial-port`, stop each UUID, verify)

### Test 6 — Non-interactive, configured
**Context**: `CI=true`, `GENYMOTION_PLATFORM=saas`, `GENYMOTION_SAAS_RECIPE=<recipe_uuid>`, `GENYMOTION_API_TOKEN` set
**Task**: "Run the instrumented tests on an Android device" in an opted-in project

Expected behavior:
1. No question asked
2. Platform and recipe taken from the environment
3. Instance started with `--max-run-duration` set to `GENYMOTION_MAX_RUN_DURATION` (default 60 minutes)
4. Polling narrated only on state changes and the final result
5. Tests run; instance stopped and the stop verified

### Test 7 — Non-interactive, nothing configured
**Context**: `CI=true`, no `GENYMOTION_*` setting, no `.genymotion.json`
**Task**: "Start a Genymotion Cloud instance and install app.apk"

Expected behavior:
1. Platform resolved from the request (Cloud), recipe missing
2. No question asked, no instance started
3. The configuration message of `references/configuration.md` printed, naming `GENYMOTION_SAAS_RECIPE`
4. With `fanout.sh`: exit code 2, nothing started

### Test 8 — Partial failure
**User says**: "Start 3 Genymotion Cloud devices and run the smoke tests" (one instance fails to boot)

Expected behavior:
1. `fanout.sh start --count 3` returns exit code 0 with one instance `BOOT_FAILED` (or `START_FAILED`, `TIMEOUT`, `ADB_FAILED`)
2. The failed instance is already stopped; it is reported as failed ("requested 3, usable 2")
3. Tests run only on the `ONLINE` instances
4. `fanout.sh stop --run <run_id>` run and verified
5. When fewer than `--min` instances are usable: exit code 1, everything already stopped, failure reported

### Test 9 — Handoff to Android tooling
**User says**: "Find the memory leak in the checkout journey" (project opted in, Genymotion SaaS configured)

Expected behavior:
1. Skill triggered by the opt-in, not by a Genymotion mention
2. Device provisioned with this skill: instance started with `--max-run-duration`, ONLINE verified, `adbconnect`, serial confirmed by `adb devices`
3. No device created with the Android CLI's emulator management or the AVD manager
4. The ADB serial handed to the Android CLI or Android Studio tools (install, Logcat, LeakCanary heap dump)
5. At the end: `gmsaas instances stop <instance_uuid>`, then `gmsaas instances list` → instance no longer listed

### Test 10 — SDK path not configured
**Context**: `CI=true`, `GENYMOTION_API_TOKEN` set, Genymotion SaaS configured, no Android SDK path in `gmsaas`
**Task**: "Run the UI tests on a Genymotion Cloud device"

Expected behavior:
1. `gmsaas doctor` fails on the Android SDK path
2. No `gmsaas instances start` run
3. Stops with a message that names `android-sdk-path` (`gmsaas config set android-sdk-path <path>`, `references/setup-gmsaas.md`)

### Test 11 — Start fails or times out
**Context**: `gmsaas instances start` exits non-zero, or the tool call times out

Expected behavior:
1. `gmsaas instances list` run
2. The instance found by the exact name given to `start`
3. If listed: `gmsaas instances stop <instance_uuid>`, then the stop verified
4. The failure reported; no ADB connect, no tests

### Test 12 — Human present, client without a question tool
**Context**: a client with no question tool (for example Codex), a human in the conversation, nothing configured, no `CI`
**User says**: "Start an Android device on Genymotion"

Expected behavior:
1. Interactive mode
2. The platform question, then the recipe or device question, asked as plain text; the agent waits for each answer
3. No configuration message

### Test 13 — Stop passes through STOPPED
**Context**: after `gmsaas instances stop <instance_uuid>`, `gmsaas instances list` shows the instance as `STOPPED`, then no longer lists it

Expected behavior:
1. `STOPPED` read as "on its way out": checked again, 10 seconds apart, up to 12 times
2. The instance no longer listed → stop verified and reported
3. No second `gmsaas instances stop`

### Test 14 — Raw parallel flow, custom prefix, one UUID lost
**Context**: no shell scripts, `GENYMOTION_INSTANCE_PREFIX=ci-team`; another run's instance `ci-team-<other-run-id>-1` is running

Expected behavior:
1. Instances named `ci-team-<run-id>-1`, `ci-team-<run-id>-2`, …
2. One UUID lost: recovered from `gmsaas instances list` by the full run prefix `ci-team-<run-id>-` only
3. Every instance of the run stopped and verified
4. `ci-team-<other-run-id>-1` left running

### Test 15 — Single start times out, an older instance has the same name
**Context**: the name check was skipped or raced, so an older instance named `pixel-8` is running; `gmsaas instances start <recipe_uuid> "pixel-8" --max-run-duration 60` times out

Expected behavior:
1. `gmsaas instances list` shows two `pixel-8` instances
2. Only the one created after the start (`created_at`) is stopped and verified; in interactive mode, the user may be asked instead
3. The older `pixel-8` keeps running

### Test 15b — Name already listed before the start
**Context**: `gmsaas instances list` shows an instance named `pixel-8` before the start

Expected behavior:
1. A different name is chosen (for example `<prefix>-<run-id>-1`) and passed to `gmsaas instances start`
2. No two instances share a name

### Test 16 — `fanout.sh start` killed while another run is recorded
**Context**: another agent's run is recorded in the same directory; this agent's `fanout.sh start` is killed by a tool timeout before it prints its JSON

Expected behavior:
1. The run id read from the standard error of `start`
2. `fanout.sh stop --run <that run id>` run and verified
3. No flagless `stop`; the other agent's run keeps running
