---
name: genymotion
description: Manages Android virtual devices on Genymotion Cloud (gmsaas) or Desktop
  (gmtool). Use when user asks to launch, start, stop, list or create virtual devices,
  install APKs, connect ADB, embed a device in a web page, run CI/CD tests, or any
  Genymotion-related task. Do NOT use for generic Android development questions
  unrelated to Genymotion device management.
compatibility: Requires gmsaas (pip install gmsaas) for Cloud workflows, or Genymotion
  Desktop with gmtool for local workflows. ADB required for device operations.
allowed-tools: "Bash AskUserQuestion Read Glob"
metadata:
  author: Genymotion
  version: 1.0.0
  category: developer-tools
  tags: [android, genymotion, emulator, mobile-testing, adb, cloud, saas]
  documentation: https://docs.genymotion.com
  support: https://github.com/Genymobile/genymotion-skills/issues
license: MIT
---

# Genymotion Unified Skill

This skill is the main entry point for all Genymotion virtual device management tasks.
It handles both **Genymotion SaaS** (via `gmsaas`) and **Genymotion Desktop** (via `gmtool`).

---

## Step 1 — Determine the Target Platform

**If the user's request does not clearly specify Cloud or Local**, ask before proceeding:

```
AskUserQuestion:
  "Which platform do you want to use?"
  Options:
    - "Genymotion SaaS / Cloud (gmsaas) — remote device in the cloud"
    - "Genymotion Desktop / Local (gmtool) — local device on this machine"
```

**Keywords that imply Cloud**: "cloud", "SaaS", "remote", "gmsaas", "Genymotion Cloud"
**Keywords that imply Local**: "local", "desktop", "gmtool", "on my machine"

---

## Step 2 — Check Prerequisites

### For Genymotion SaaS (gmsaas)

**Step 2a — Locate gmsaas**

Detect the OS first, then check if `gmsaas` is available in PATH:

- **Linux / macOS**: `which gmsaas`
- **Windows (PowerShell)**: `where.exe gmsaas`

- **If found in PATH**: use `gmsaas` directly for all subsequent commands.
- **If NOT found in PATH**: do NOT search directories yourself. Ask the user:

> "gmsaas was not found in PATH. Do you have a Python virtualenv where gmsaas is installed?"
> - Yes — I will provide the path to the venv
> - No — I need to install gmsaas

  - If the user provides a venv path, use the appropriate binary:
    - Linux / macOS: `<venv_path>/bin/gmsaas`
    - Windows: `<venv_path>\Scripts\gmsaas`
  - If gmsaas is not installed, follow `references/setup-gmsaas.md`

**Step 2b — Check authentication**

Once `gmsaas` is located, run `gmsaas doctor` to verify the setup.

**If gmsaas IS found but not authenticated**, identify the issue with `gmsaas doctor` and guide the user through setup.

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

**If gmtool is NOT found**, follow `references/setup-gmtool.md`

**If gmtool IS found but licence inactive** (exit code 9):
```
gmtool license info                  # Check licence status
gmtool license register <key>        # Register a licence key
```

---

## Step 3 — Execute the Requested Action

Once the platform is confirmed and prerequisites are met, read the appropriate reference file and follow its instructions:

- **For Genymotion SaaS (gmsaas)** → Read `references/gmsaas-reference.md`
- **For Genymotion Desktop (gmtool)** → Read `references/gmtool-reference.md`

The reference files are located in the `references/` directory:
- `references/gmsaas-reference.md`
- `references/gmtool-reference.md`

---

## Verify Start / Stop Operations

**Always verify the actual state after a start or stop command.** Never assume success based solely on the command's exit code or lack of error output.

### Genymotion SaaS (gmsaas)

After `gmsaas instances start`:

Poll until status is `ONLINE` using the following strategy:

```
Repeat up to 10 times (max ~5 minutes):
  Run: gmsaas instances get <instance_uuid>
  If status = "ONLINE"  → proceed, inform the user the instance is ready
  If status = "BOOTING" → wait 30 seconds, then retry
  If status is anything else (ERROR, DELETING, unknown) → stop polling, inform the user and suggest checking https://cloud.geny.io/instances

If still not ONLINE after 10 attempts (~5 minutes):
  → Inform the user: "The instance is taking longer than expected to start.
     You can check its status at https://cloud.geny.io/instances or run:
     gmsaas instances get <instance_uuid>"
  → Do not proceed with ADB connect or further steps
```

Between each poll, tell the user what you are doing: *"Instance is BOOTING — checking again in 30 seconds (attempt N/10)…"*

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
# Or: gmsaas instances get <instance_uuid> → status = "STOPPED" / "OFFLINE"
# If instance still appears as running: retry the stop command or ask the user to check the cloud dashboard
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

## Stop a SaaS Instance

**Keywords that trigger this flow**: "stop", "arrêter", "delete", "supprimer", "shut down", "kill", combined with "instance", "cloud", "gmsaas"

> SaaS instances are billed as long as they are running. Always offer to stop the instance when the user's task is complete, or when they ask how to avoid charges.

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

### Prerequisites

- A running SaaS instance (if not started yet, start it first — see Step 2)
- Retrieve the instance UUID if not already known: `gmsaas instances list`

> A **recipe** defines the virtual device configuration (Android version + hardware profile).
> Think of it as a device template. Before starting an instance, you need to pick a recipe UUID.
> List available recipes with: `gmsaas recipes list`

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
1. Identify the target platform (Cloud or Local) → ask if ambiguous
2. Check prerequisites (gmsaas or gmtool installed + authenticated/licensed)
   → If missing: guide the user through installation step by step
3. Read the corresponding reference file
4. Identify the requested action
5. Collect missing parameters (name, UUID, profile…) via list + AskUserQuestion
6. Execute the command via Bash
7. Verify the result with the appropriate check command (see "Verify Start / Stop Operations")
8. Report the verified state to the user — never assume success without checking
9. Handle errors (show the message + suggest a solution)
10. [SaaS only] Remind the user to stop the instance when done to avoid charges
```

---

## Examples

### Example 1 — Start a Cloud instance and install an APK

User says: *"Start a Pixel 8 on Genymotion Cloud and install my app.apk"*

Actions:
1. Detect platform = Cloud → check gmsaas
2. `gmsaas recipes list` → ask user to pick a Pixel 8 recipe
3. `gmsaas instances start <recipe_uuid> "pixel-8" --max-run-duration 3600`
4. `gmsaas instances get <instance_uuid>` → verify status = ONLINE before proceeding
5. `gmsaas instances adbconnect <instance_uuid>`
6. `adb install app.apk`
7. Remind user: `gmsaas instances stop <instance_uuid>` when done

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

## Troubleshooting

### gmsaas not found in PATH
**Cause**: gmsaas is not installed or not in PATH.
**Solution**: Run `which gmsaas` (Linux/macOS) or `where.exe gmsaas` (Windows). If missing, see `references/setup-gmsaas.md`. If installed in a virtualenv, provide the full path: `<venv>/bin/gmsaas` or `<venv>\Scripts\gmsaas`.

### Auth error — 401 / Unauthorized
**Cause**: API token not set, expired, or revoked.
**Solution**: Run `gmsaas doctor` to identify the issue. Set the token via environment variable (do not run via Bash tool):
- Linux/macOS: `export GENYMOTION_API_TOKEN="your_token"`
- Windows: `$env:GENYMOTION_API_TOKEN = "your_token"`

### Instance stuck in BOOTING
**Cause**: Cloud instance startup can take 1–3 minutes. Rarely, the instance may fail to boot.
**Solution**: Poll `gmsaas instances get <uuid>` every 30 seconds, up to 10 attempts. If still not ONLINE after 5 minutes, inform the user and point to https://cloud.geny.io/instances.

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

- `Bash` — to run `gmsaas` and `gmtool`
- `AskUserQuestion` — to disambiguate the platform and collect missing parameters
- `Read` — to read the reference files `references/gmsaas-reference.md`, `references/gmtool-reference.md`, `references/device-web-player-reference.md`
- `Glob` / `Read` — to locate local APK files or archives
