---
name: genymotion
description: >-
  Manages Android virtual devices on Genymotion SaaS/Cloud (gmsaas) or Genymotion
  Desktop (gmtool). Use when the user asks to launch, start, stop, list or create
  Android virtual devices or emulators, install APKs, connect ADB, run several
  Genymotion devices in parallel, embed a device in a web page, run CI/CD tests, or mentions
  Genymotion, gmsaas or gmtool. Also use when a task only needs an Android device
  or emulator to run, test, debug or verify a change AND the project has opted in
  to Genymotion: its CLAUDE.md or AGENTS.md says to use Genymotion for Android
  devices, or a .genymotion.json file exists at the repository root. Do NOT use
  for generic Android development questions (how to use ADB, test frameworks,
  which emulator is best), or for tasks that only need a device in projects that
  have not opted in.
compatibility: Requires gmsaas (pip install gmsaas) for Cloud workflows, or Genymotion
  Desktop with gmtool for local workflows. ADB required for device operations.
allowed-tools: "Bash AskUserQuestion Read Glob"
metadata:
  author: Genymotion
  version: 1.1.0
  category: developer-tools
  tags: [android, genymotion, emulator, mobile-testing, adb, cloud, saas]
  documentation: https://docs.genymotion.com
  support: https://github.com/Genymobile/genymotion-skills/issues
license: MIT
---

# Genymotion Unified Skill

This skill is the main entry point for all Genymotion virtual device management tasks.
It handles both **Genymotion SaaS** (via `gmsaas`) and **Genymotion Desktop** (via `gmtool`).

**Opt-in.** Explicit requests to manage a virtual device, and any mention of Genymotion, always use this skill. A task that only needs a device as a means (run the tests, verify a fix…) uses it when the project has opted in:

- its `CLAUDE.md` or `AGENTS.md` carries the `## Android devices` block of the README, or
- a `.genymotion.json` file exists at the repository root (seen only once you look at the repository root).

---

## Configuration and Non-interactive Mode

Settings (platform, recipe, Desktop device, maximum run duration, instance cap…) come from the task, the `GENYMOTION_*` environment variables or `.genymotion.json`, in the order given in `references/configuration.md`. Read that file when you need a setting. An invalid value is a configuration error, handled as that file says.

Read the environment only with the explicit-name command of `references/configuration.md`; never `env`, `printenv` or a `GENYMOTION` wildcard on its own: the API token must never be printed.

**Non-interactive mode** applies when `CI=true`, when `GENYMOTION_NONINTERACTIVE=1`, or when the agent has no way to ask: no question tool and no human reading the conversation (background agent, sub-agent, scheduled run). In that mode:

- Never ask a question. Every `AskUserQuestion` block and every question in this file and in the reference files is for interactive mode only. Use the configured value, or stop and print the configuration message of `references/configuration.md`.
- While polling, report only state changes and the final result.
- Still verify every start and stop, and still stop every SaaS instance at the end.

In interactive mode with nothing configured, ask the questions below as written. A human chatting with a client that has no question tool (Codex, Gemini, Copilot, Cursor…) is still interactive: ask the same questions as plain text in your reply, and wait for the answer.

---

## Step 1 — Determine the Target Platform

Resolve the platform in this order (details in `references/configuration.md`):

1. **Explicit request.** Keywords that imply Cloud: "cloud", "SaaS", "remote", "gmsaas", "Genymotion Cloud". Keywords that imply Local: "local", "desktop", "gmtool", "on my machine".
2. **Environment**: `GENYMOTION_PLATFORM` (`saas` or `desktop`).
3. **Project file**: `platform` in `.genymotion.json` at the repository root.
4. **Implied platform**: if only a recipe is configured, use SaaS; if only a Desktop device is configured, use Desktop.
5. **Interactive mode**: ask.
6. **Non-interactive mode**: stop and print the configuration message for `GENYMOTION_PLATFORM`.

Interactive question:

```
AskUserQuestion:
  "Which platform do you want to use?"
  Options:
    - "Genymotion SaaS / Cloud (gmsaas) — remote device in the cloud"
    - "Genymotion Desktop / Local (gmtool) — local device on this machine"
```

---

## Step 2 — Check Prerequisites

In non-interactive mode, never ask during this step. When a prerequisite is missing, stop with a message that says what to install or set, as shown below.

### For Genymotion SaaS (gmsaas)

**Step 2a — Locate gmsaas**

Detect the OS first, then check if `gmsaas` is available in PATH:

- **Linux / macOS**: `which gmsaas`
- **Windows (PowerShell)**: `where.exe gmsaas`

- **If found in PATH**: use `gmsaas` directly for all subsequent commands.
- **If NOT found in PATH**: do NOT search directories yourself.
  - **Non-interactive mode**: stop with *"gmsaas was not found in PATH. Install it (`pip install gmsaas`, see `references/setup-gmsaas.md`) or add the directory that contains it to PATH."*
  - **Interactive mode**: ask the user:

> "gmsaas was not found in PATH. Do you have a Python virtualenv where gmsaas is installed?"
> - Yes — I will provide the path to the venv
> - No — I need to install gmsaas

  - If the user provides a venv path, use the appropriate binary:
    - Linux / macOS: `<venv_path>/bin/gmsaas`
    - Windows: `<venv_path>\Scripts\gmsaas`
  - If gmsaas is not installed, follow `references/setup-gmsaas.md`

**Step 2b — Check authentication and the Android SDK path**

Once `gmsaas` is located, run `gmsaas doctor`. **It must exit 0 before any `gmsaas instances start`.** `instances start` needs only the token, but `get`, `list`, `adbconnect` and `stop` also need the Android SDK path: without it you could start a billed instance that you cannot stop.

If `gmsaas doctor` fails, identify the issue from its output.

- **Not authenticated**, non-interactive mode: stop with *"gmsaas is not authenticated. Set `GENYMOTION_API_TOKEN` in the environment (as a CI secret in a pipeline). See `references/setup-gmsaas.md`."*
- **Android SDK path not set**, non-interactive mode: stop with *"Android SDK path not set: run `gmsaas config set android-sdk-path <path>`, see `references/setup-gmsaas.md`."*
- **Interactive mode**: guide the user through setup.

> **SECURITY — Never run `gmsaas auth token <token>` via the Bash tool.**
> The token would be exposed in the shell history. Instead, display the command for the user to run themselves in their own terminal:
> ```bash
> # Linux / macOS:
> export GENYMOTION_API_TOKEN="your_token"
>
> # Windows (PowerShell):
> $env:GENYMOTION_API_TOKEN = "your_token"
> ```

---

### For Genymotion Desktop (gmtool)

Run: `gmtool version`

**If gmtool is NOT found**, follow `references/setup-gmtool.md`. In non-interactive mode, stop with *"gmtool was not found in PATH. Install Genymotion Desktop and add its directory to PATH (see `references/setup-gmtool.md`)."*

**If gmtool IS found but licence inactive** (exit code 9):
```
gmtool license info                  # Check licence status
gmtool license register <key>        # Register a licence key
```

In non-interactive mode, stop and report that the licence must be registered; never ask for a key.

---

## Step 3 — Execute the Requested Action

Once the platform is confirmed and prerequisites are met, read the appropriate reference file and follow its instructions:

- **For Genymotion SaaS (gmsaas)** → Read `references/gmsaas-reference.md`
- **For Genymotion Desktop (gmtool)** → Read `references/gmtool-reference.md`
- **For several devices at once** → Read `references/parallel-reference.md`
- **For settings and unattended use** → Read `references/configuration.md`

The reference files are located in the `references/` directory:
- `references/gmsaas-reference.md`
- `references/gmtool-reference.md`
- `references/parallel-reference.md`
- `references/configuration.md`

### Choosing the device

1. **Explicit request**: a recipe or device named in the task.
2. **Configuration**: the SaaS recipe (`GENYMOTION_SAAS_RECIPE` / `saasRecipe`, a UUID or a name from `recipes`) or the Desktop device (`GENYMOTION_DESKTOP_DEVICE` / `desktopDevice`).
3. **Interactive mode**: list (`gmsaas recipes list` or `gmtool admin list`) and ask the user to pick.
4. **Non-interactive mode**: stop with the configuration message.

When the task names a device kind that is not in `recipes`, do not guess (see `references/configuration.md`).

### Starting a SaaS instance

- **Always pass `--max-run-duration`**, in minutes, set to `GENYMOTION_MAX_RUN_DURATION` / `maxRunDuration` (default `60`). Never pass `0`: for `gmsaas` it means "no limit".
- `gmsaas instances start` waits until the instance is up, for up to 5 minutes. Give the command a timeout of at least 6 minutes.
- Give the instance a name that no listed instance has: check `gmsaas instances list` first, or use `<prefix>-<run-id>-1` (see `references/parallel-reference.md`).
- **If it exits non-zero, or the tool call times out, an instance may exist anyway.** Run `gmsaas instances list`, find the instance by the exact name you gave, stop it and verify the stop (see "Verify Start / Stop Operations"), then report the failure.
  - If more than one instance has that name, stop only the one created after your start (`created_at` in `gmsaas --format compactjson instances list`). In interactive mode, ask the user when in doubt.
  - Never stop an instance that you cannot tie to your own start.
- `gmsaas instances stop` can block for up to about 3 minutes: give it a timeout of at least 3 minutes. The stop verification decides the outcome either way.

---

## Multiple Devices

Read `references/parallel-reference.md` before starting more than one device.

- **SaaS, with shell access**: use `fanout.sh`, in the `scripts/` directory next to this `SKILL.md`. Run it from the project root and call it by its path; never `cd` into the skill directory.
- `start` can run for several minutes: give it a timeout of at least 10 minutes, or run it in the background. It writes its run id on standard error before it starts any instance: if `start` ends without printing its JSON, run `fanout.sh stop --run <run-id>` at once with that id. Use `stop` without a flag only when no other run is active in this directory.
- Keep the `run_id` from the JSON that `start` prints, and read the `status` of each instance: only `ONLINE` instances are usable.
- **Always finish with `fanout.sh stop --run <run_id>`**, also when the tests fail.
- **SaaS, without shell scripts**: follow the raw `gmsaas` steps of the reference.
- **Desktop**: host resources limit you to 2–3 devices; use SaaS for more.

```bash
FANOUT=.claude/skills/genymotion/scripts/fanout.sh   # example: adapt to where the skill is installed
RESULT="$("$FANOUT" start --count 3 --recipe phone)"
RUN_ID="$(jq -r '.run_id' <<<"$RESULT")"
# run the tests on each serial whose status is ONLINE
"$FANOUT" stop --run "$RUN_ID"
```

---

## Verify Start / Stop Operations

**Always verify the actual state after a start or stop command.** Never assume success based solely on the command's exit code or lack of error output.

### Genymotion SaaS (gmsaas)

After `gmsaas instances start`:

Poll until the instance state is `ONLINE` using the following strategy:

```
Repeat up to 10 times (max ~5 minutes):
  Run: gmsaas instances get <instance_uuid>
  If state = "ONLINE" → proceed, inform the user the instance is ready
  If state is a starting state — "CREATING", "STARTING", "OFFLINE", "BOOTING" or "UNKNOWN"
    → wait 30 seconds, then retry
  If state is anything else (ERROR, STOPPING, DELETING…) or the instance is not found
    → stop polling; the instance is unusable: stop it if it is still listed, and verify the stop
    → inform the user and suggest checking https://cloud.geny.io/instances

If still not ONLINE after 10 attempts (~5 minutes):
  → The instance is unusable: stop it and verify the stop
  → Inform the user: "The instance took longer than expected to start, so I stopped it.
     You can check https://cloud.geny.io/instances"
  → Do not proceed with ADB connect or further steps
```

Between each poll, tell the user what you are doing: *"Instance is BOOTING — checking again in 30 seconds (attempt N/10)…"*. In non-interactive mode, report only state changes and the final result.

After `gmsaas instances adbconnect`:

```bash
adb devices
# Expected: instance appears in the list (e.g. "localhost:5555  device")
# If list is empty despite successful adbconnect:
#   → The local ADB daemon may not be running. Start it:
gmsaas adb start
#   → Then retry: adb devices
# If still empty: run gmsaas doctor to check the Android SDK path configuration
```

After `gmsaas instances stop`:

```bash
gmsaas instances list
# Expected: instance no longer appears in the list
# Listed as STOPPING, STOPPED, OFFLINE or DELETING: on its way out.
#   Check again, up to 12 times, 10 seconds apart, until it is no longer listed.
# Listed in any other state, or still listed after the last check:
#   stop it again, then point the user to https://cloud.geny.io/instances
```

### Genymotion Desktop (gmtool)

After `gmtool admin start <device>`:

```bash
gmtool admin list --running
# Expected: device appears in the list with State = On
# If not listed: check exit code, try gmtool admin details <device> for more info
```

After `gmtool admin stop <device>`:

```bash
gmtool admin list --off
# Expected: device appears with State = Off
# If still listed as running: retry stop or ask the user to close Genymotion Desktop
```

> **Report the verified state to the user.** Don't say "the device is started" — say "I confirmed the device is running: `gmtool admin list --running` shows it with State = On."

---

## After the device is connected: using Android tooling

- A connected Genymotion device (SaaS through `gmsaas instances adbconnect`, or Desktop) is a standard ADB device. Use it with the Android CLI and Android Studio tools as you would Google's emulator: build and install, Logcat, UI inspection, LeakCanary heap dumps, and crash investigation with `android signals`. Target it by its ADB serial (`adb devices`).
- Genymotion Desktop devices appear in Android Studio's device list like the Google emulator. Agents connected through Android Studio's Bring Your Own Agent can use them directly.
- When Genymotion is the configured platform, create and stop devices with this skill, not with the Android CLI's emulator management or the AVD manager. Use `android device remote` only if the user asks for Google's physical lab devices.
- Always stop Genymotion SaaS instances at the end of the task, including after a handoff to other tools.

---

## Stop a SaaS Instance

**Keywords that trigger this flow**: "stop", "arrêter", "delete", "supprimer", "shut down", "kill", combined with "instance", "cloud", "gmsaas"

> SaaS instances are billed as long as they are running. Always offer to stop the instance when the user's task is complete, or when they ask how to avoid charges. An agent that started instances on its own stops them itself at the end of its task.

### Stop a single instance

```bash
# List running instances to get the UUID
gmsaas instances list

# Stop the instance
gmsaas instances stop <instance_uuid>
```

### Stop all running instances

If the user wants to stop everything at once:

```bash
# List all running instances and stop each one
gmsaas instances list
# Then for each instance UUID:
gmsaas instances stop <instance_uuid>
```

> **Proactive guidance**: After any workflow that starts a SaaS instance (APK install, testing, display…), remind the user:
> *"Don't forget to stop your instance when you're done to avoid charges: `gmsaas instances stop <instance_uuid>`"*

---

## Display a SaaS Instance

**Keywords that trigger this flow**: "display", "open", "show", "view", combined with "cloud instance", "SaaS instance" or "gmsaas instance"

When the user wants to display a running SaaS instance, offer the following options:

```
AskUserQuestion:
  "How would you like to display your Genymotion SaaS instance?"
  Options:
    - "Open in the Genymotion Cloud web interface"
    - "Open via gmsaas instances display (opens and copies the link to clipboard)"
    - "Embed it in a custom web page (device-web-player SDK)"
```

In non-interactive mode, do not ask: give the web interface URL (Option 1).

### Prerequisites

- A running SaaS instance (if not started yet, start it first — see "Starting a SaaS instance" in Step 3)
- Retrieve the instance UUID if not already known: `gmsaas instances list`

> A **recipe** defines the virtual device configuration (Android version + hardware profile).
> Think of it as a device template. Before starting an instance, you need a recipe UUID: the configured one, or one picked from `gmsaas recipes list`.

### Option 1 — Open in the Genymotion Cloud web interface

Provide the user with the URL to open directly in their browser:

```
https://cloud.geny.io/instance/<instance_uuid>
```

> The user must be logged in to https://cloud.geny.io beforehand. Remind them to log in if this is their first time or if their session may have expired.

### Option 2 — Open via gmsaas instances display

```bash
gmsaas instances display <instance_uuid>
```

> **Note**: this command copies the instance display link to the clipboard and may open it automatically in the default browser. Inform the user that the link has been copied to their clipboard.

### Option 3 — Embed in a custom web page

→ Follow the **Display a SaaS Instance in a Web Page (device-web-player)** section below.

---

## Display a SaaS Instance in a Web Page (device-web-player)

**Keywords that trigger this flow**: "web page", "embed", "browser", "device-web-player", "html page", "integrate", "web player", combined with "cloud instance" or "SaaS"

Read `references/device-web-player-reference.md` and follow the **Step-by-step Workflow** section.

Key behaviors to always apply:
- **NEVER execute curl commands via Bash tool** — they return secrets
- **NEVER ask the user to paste tokens into the chat** — display commands for them to run in their own terminal
- Always offer two options: default template (`templates/device-web-player.html`) or custom design
- Remind the user to serve via HTTP (not `file://`) for WebRTC to work

---

## CI/CD Integration

**Keywords that trigger this flow**: "CI/CD", "pipeline", "GitHub Actions", "Jenkins", "Bitrise", "CircleCI", "continuous integration", "automated tests", "Detox", "Appium", combined with "Genymotion" or "SaaS"

CI/CD integration is only supported with **Genymotion SaaS** (`gmsaas`), not Genymotion Desktop (`gmtool`).
If the user asks about CI/CD with Genymotion Desktop, explain this limitation and redirect to SaaS.

Read `references/cicd-reference.md` for platform-specific tutorials and the general integration pattern.

---

## General Workflow Summary

```
1. Identify the target platform (Cloud or Local) → request, environment, .genymotion.json;
   ask only in interactive mode, otherwise stop with the configuration message
2. Check prerequisites (gmsaas or gmtool installed + authenticated/licensed)
   → If missing: guide the user (interactive) or stop with what to install or set (non-interactive)
3. Read the corresponding reference file
4. Identify the requested action
5. Collect missing parameters (recipe, device name, UUID…) from the request and the configuration;
   list + AskUserQuestion only in interactive mode
6. Execute the command via Bash (SaaS start: always --max-run-duration, in minutes)
7. Verify the result with the appropriate check command (see "Verify Start / Stop Operations")
8. Report the verified state to the user — never assume success without checking
9. Handle errors (show the message + suggest a solution)
10. [SaaS only] Stop the instances you started at the end of the task, or remind the user to stop them
```

---

## Examples

### Example 1 — Start a Cloud instance and install an APK

User says: *"Start a Pixel 8 on Genymotion Cloud and install my app.apk"*

Actions:
1. Detect platform = Cloud → check gmsaas
2. Use the configured recipe if it is a Pixel 8; otherwise `gmsaas recipes list` → ask user to pick a Pixel 8 recipe
3. `gmsaas instances start <recipe_uuid> "pixel-8" --max-run-duration 60`
4. `gmsaas instances get <instance_uuid>` → verify state = ONLINE before proceeding
5. `gmsaas instances adbconnect <instance_uuid>` → note the ADB serial it prints
6. `adb -s <serial> install app.apk`
7. Remind user: `gmsaas instances stop <instance_uuid>` when done
8. When the user says they are done, or when the agent started the instance for its own task: stop it and verify the stop

Result: APK installed and running on a live cloud instance. Instance state was verified before ADB connection. User is reminded to stop it to avoid charges.

---

### Example 2 — Start a local Desktop device and debug

User says: *"Lance un device Android 13 en local et montre-moi les logs"*

Actions:
1. Detect platform = Local → check gmtool
2. `gmtool admin list` → identify an Android 13 device
3. `gmtool admin start "Pixel 7 API 33"`
4. `gmtool admin list --running` → verify device appears with State = On
5. `gmtool device logcatdump -n "Pixel 7 API 33" ~/debug.log`

Result: Device started and verified running before capturing logs.

---

### Example 3 — Embed a cloud instance in a web page

User says: *"I want to display my Genymotion instance in an HTML page"*

Actions:
1. Detect flow = device-web-player
2. Check instance is running → `gmsaas instances list`
3. Ask user: default template or custom design?
4. Copy `templates/device-web-player.html` (or generate custom)
5. Display curl commands for the user to run in their terminal (webrtc_url + access token)
6. Instruct user to replace `REPLACE_WITH_WSS_ADDRESS` and `REPLACE_WITH_ACCESS_TOKEN`
7. Remind to serve via HTTP: `python3 -m http.server 8080`

Result: Ready-to-use HTML page streaming the device via WebRTC.

---

### Example 4 — Set up Genymotion in a GitHub Actions pipeline

User says: *"How do I use Genymotion in my GitHub Actions CI?"*

Actions:
1. Detect flow = CI/CD → read `references/cicd-reference.md`
2. Clarify: CI/CD is only supported with Genymotion SaaS, not Desktop
3. Point to the GitHub Actions resource: https://github.com/marketplace/actions/genymotion-saas-action
4. Show the general pattern: auth → start instance → adbconnect → run tests → stop instance
5. Remind to store `GENYMOTION_API_TOKEN` as a CI secret

Result: User has a working starting point for their CI pipeline.

---

### Example 5 — Unattended agent in an opted-in project

Task: *"Run the UI tests and confirm the fix works"*, with `CI=true`, `GENYMOTION_PLATFORM=saas` and `GENYMOTION_SAAS_RECIPE` set.

Actions:
1. Opt-in found (the `## Android devices` block in `CLAUDE.md` / `AGENTS.md`, or `.genymotion.json`) → use this skill
2. Non-interactive mode → no question; platform and recipe come from the environment
3. `gmsaas doctor` exits 0, then `gmsaas instances start <recipe_uuid> "<prefix>-<run-id>-1" --max-run-duration 60` (configured prefix, default `agent`; a unique run id, as in `references/parallel-reference.md`)
4. Poll until ONLINE, `gmsaas instances adbconnect <instance_uuid>`, check `adb devices`
5. Run the tests against the device's ADB serial
6. `gmsaas instances stop <instance_uuid>`, then `gmsaas instances list` → verify it is gone

Result: Tests ran on a verified device, and the instance was stopped and verified, without any question asked.

---

## Troubleshooting

### gmsaas not found in PATH
**Cause**: gmsaas is not installed or not in PATH.
**Solution**: Run `which gmsaas` (Linux/macOS) or `where.exe gmsaas` (Windows). If missing, see `references/setup-gmsaas.md`. If installed in a virtualenv, provide the full path: `<venv>/bin/gmsaas` or `<venv>\Scripts\gmsaas`.

### Auth error — 401 / Unauthorized
**Cause**: API token not set, expired, or revoked.
**Solution**: Run `gmsaas doctor` to identify the issue. Set the token via environment variable (do not run via Bash tool):
- Linux/macOS: `export GENYMOTION_API_TOKEN="your_token"`
- Windows: `$env:GENYMOTION_API_TOKEN = "your_token"`

### Instance stuck while starting
**Cause**: Cloud instance startup can take 1–3 minutes, through the starting states `CREATING`, `STARTING`, `OFFLINE`, `BOOTING` or `UNKNOWN`. Rarely, the instance may fail to boot.
**Solution**: Poll `gmsaas instances get <uuid>` every 30 seconds, up to 10 attempts. If still not ONLINE after 5 minutes, stop the instance, verify the stop, inform the user and point to https://cloud.geny.io/instances.

### adb devices empty after adbconnect
**Cause**: The local ADB daemon is not running.
**Solution**: Run `gmsaas adb start`, then retry `adb devices`. If still empty, run `gmsaas doctor` to verify the Android SDK path.

### gmtool licence not activated (exit code 9)
**Cause**: Genymotion Desktop licence not registered.
**Solution**: `gmtool license info` to check status, then `gmtool license register <key>` to activate.

### gmtool device not found (exit code 5)
**Cause**: Device name is incorrect or the device has not been created yet.
**Solution**: Run `gmtool admin list` to get the exact device names. If the device does not exist, create it first.

### gmtool virtualisation engine not responding (exit code 4)
**Cause**: Genymotion Desktop is not running or the hypervisor crashed.
**Solution**: Open Genymotion Desktop and wait for it to be ready, then retry.

---

## Tools Used

- `Bash` — to run `gmsaas`, `gmtool` and `scripts/fanout.sh`
- `AskUserQuestion` — in interactive mode only, to disambiguate the platform and collect missing parameters that the configuration does not give (a plain-text question when the client has no question tool)
- `Read` — to read the reference files `references/gmsaas-reference.md`, `references/gmtool-reference.md`, `references/parallel-reference.md`, `references/configuration.md`, `references/device-web-player-reference.md`
- `Glob` / `Read` — to locate local APK files or archives, and `.genymotion.json` at the repository root
