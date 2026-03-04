---
name: genymotion-skills
description: Use this skill when the user wants to manage Android virtual devices on any Genymotion platform (Cloud/SaaS with gmsaas, or local Desktop with gmtool). Triggers on generic requests like "launch an Android device", "start a device", "list my devices", "create a virtual device", "install an APK", "connect ADB", or any Genymotion-related task where the target platform is not explicitly specified.
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

Check if `gmsaas` is available in PATH:

```bash
which gmsaas
```

- **If found in PATH**: use `gmsaas` directly for all subsequent commands.
- **If NOT found in PATH**: do NOT search directories yourself. Ask the user:

```
AskUserQuestion:
  "gmsaas was not found in PATH. Do you have a Python virtualenv where gmsaas is installed?"
  Options:
    - "Yes — I will provide the path to the venv"
    - "No — I need to install gmsaas"
```

  - If the user provides a venv path (e.g. `/home/user/.venv`), use `<venv_path>/bin/gmsaas` for all subsequent commands.
  - If gmsaas is not installed, guide the user:

```
1. Install gmsaas in a virtualenv:
   python3 -m venv .venv && source .venv/bin/activate && pip install gmsaas

   → Or globally (if the environment allows it):
   pip3 install gmsaas
   # If you get an "externally-managed-environment" error:
   pip3 install gmsaas --break-system-packages

2. Set the Android SDK path:
   gmsaas config set android-sdk-path <path_to_sdk>

3. Authenticate (get a token from https://cloud.geny.io/api):
   gmsaas auth token <your_token>
   # or via environment variable:
   export GENYMOTION_API_TOKEN="your_token"

4. Verify the setup:
   gmsaas doctor
```

**Step 2b — Check authentication**

Once `gmsaas` is located, run `gmsaas doctor` to verify the setup.

**If gmsaas IS found but not authenticated**, identify the issue with `gmsaas doctor` and guide the user through setup.

---

### For Genymotion Desktop (gmtool)

Run: `gmtool version`

**If gmtool is NOT found**, guide the user:

```
gmtool is bundled with Genymotion Desktop. To install it:

→ Linux:
  Download from https://www.genymotion.com/product-desktop/
  chmod +x genymotion-*.bin && ./genymotion-*.bin
  Then add to PATH: export PATH="$PATH:/opt/genymobile/genymotion"

→ macOS:
  Download the .dmg from https://www.genymotion.com/product-desktop/
  Drag Genymotion into Applications
  Then: export PATH="$PATH:/Applications/Genymotion.app/Contents/MacOS"

→ Windows:
  Download and run the .exe installer from https://www.genymotion.com/product-desktop/
  gmtool.exe will be in the installation folder (e.g. C:\Program Files\Genymobile\Genymotion)

After installation, verify with: gmtool version
```

**If gmtool IS found but licence inactive** (exit code 9):
```
gmtool license info                  # Check licence status
gmtool license register <key>        # Register a licence key
```

---

## Step 3 — Execute the Requested Action

Once the platform is confirmed and prerequisites are met, read the appropriate reference file and follow its instructions:

- **For Genymotion SaaS (gmsaas)** → Read `gmsaas-reference.md` in this skill directory
- **For Genymotion Desktop (gmtool)** → Read `gmtool-reference.md` in this skill directory

The reference files are located alongside this SKILL.md:
- `gmsaas-reference.md`
- `gmtool-reference.md`

---

## Cross-platform: Display a SaaS Instance via Desktop Player

**Keywords that trigger this flow**: "display", "open", "show", "view", "player", "stop", "power off", combined with "cloud instance" or "gmsaas instance"

This workflow uses **both** platforms: gmsaas to manage the instance and the Genymotion Desktop `player` binary to interact with it locally.

### Prerequisites

- gmsaas available (see Step 2 — For Genymotion SaaS)
- Genymotion Desktop installed and `player` available in PATH

### Display

```
1. Ensure the SaaS instance is running via gmsaas
   → If not started yet, start it first:
     gmsaas instances start <recipe_uuid> <name>

2. Retrieve the instance UUID if not already known:
     gmsaas instances list

3. Open the instance in the Desktop player:
     player -n <instance_uuid_or_name> --cloud
```

### Stop (power off via Desktop player)

```bash
player -n <instance_uuid_or_name> --poweroff --cloud
```

> **Warning**: this only closes the player window. The instance keeps running on Genymotion Cloud and will continue to consume resources.
> After running this command, ask the user:
>
> ```
> AskUserQuestion:
>   "The device has been powered off in the player, but the instance is still running on Genymotion SaaS.
>    Do you also want to stop it on the SaaS side?"
>   Options:
>     - "Yes — stop it on Genymotion SaaS too (gmsaas instances stop)"
>     - "No — keep it running in the cloud"
> ```
>
> If yes: `gmsaas instances stop <instance_uuid>`

### Notes

- The instance **must be started by gmsaas** before using `player --cloud`.
- `player` is bundled with Genymotion Desktop — if not found in PATH, check if the user wants to add it (see gmtool prerequisites in Step 2).
- Either the UUID or the instance name can be passed to `-n`.

### Fallback — Genymotion Desktop not available

If `player` is not available and the user does not want to install Genymotion Desktop, open the instance in the browser instead:

```
https://cloud.geny.io/instance/<instance_uuid>
```

> **Note**: the user must be logged in to https://cloud.geny.io beforehand. Remind them to log in if this is their first time or if their session may have expired.

---

## Display a SaaS Instance in a Web Page (device-web-player)

**Keywords that trigger this flow**: "web page", "embed", "browser", "device-web-player", "html page", "integrate", "web player", combined with "cloud instance" or "SaaS"

This workflow embeds a running Genymotion SaaS instance directly into a custom web page using the `@genymotion/device-web-player` SDK (WebRTC streaming, no Genymotion Desktop required).

### Prerequisites

- A running Genymotion SaaS instance (started via `gmsaas instances start` or the SaaS dashboard)
- A **Genymotion API token** (generate one at https://cloud.geny.io/api)

### Step-by-step workflow

```
1. Ensure the instance is running:
     gmsaas instances list

   → If not started yet:
     gmsaas instances start <recipe_uuid> <name>

2. Get the WebRTC address via the REST API:
     curl -H 'Content-Type: application/json;charset=utf-8' \
          -H 'x-api-token: <API_TOKEN>' \
          https://api.geny.io/cloud/v1/instances/<INSTANCE_UUID>
   → Extract the "webrtc_url" field from the response

3. Get the player access token via the REST API:
     curl -X POST \
          -H 'Content-Type: application/json;charset=utf-8' \
          -H 'x-api-token: <API_TOKEN>' \
          -d '{"instance_uuid": "<INSTANCE_UUID>"}' \
          https://api.geny.io/cloud/v1/instances/access-token
   → Use the returned token in the player

4. Use the template to generate a ready-to-use web page:
   → Copy templates/device-web-player.html
   → Replace REPLACE_WITH_WSS_ADDRESS with the webrtc_url value
   → Replace REPLACE_WITH_ACCESS_TOKEN with the access token
   → Serve with:
        npx serve .
        python3 -m http.server 8080
```

### Guiding the user

> **SECURITY — NEVER ask the user to paste their API token or access token into the chat.**
> Tokens are sensitive credentials. Always instruct the user to run the commands themselves
> in a separate terminal and to edit the HTML file directly.
> Never execute the curl commands via Bash tool (the output would contain secrets).

When the user asks to create or set up this web page:

1. Check that an instance is running — if not, start one (see Step 1 above)
2. Copy the appropriate template to the user's project directory (use Read + Write or Bash cp)
3. Display the two curl commands pre-filled with the instance UUID so the user can run them **in their own terminal**:
   - GET  `https://api.geny.io/cloud/v1/instances/<UUID>` → copy the `webrtc_url` value
   - POST `https://api.geny.io/cloud/v1/instances/access-token` → copy the returned token
4. Instruct the user to edit the HTML file themselves and replace the two constants:
   - `REPLACE_WITH_WSS_ADDRESS` → the `webrtc_url` value
   - `REPLACE_WITH_ACCESS_TOKEN`  → the access token
5. Remind the user to serve the file via HTTP (not `file://`) for WebRTC to work:
   ```bash
   python3 -m http.server 8080
   ```

### Customisation options to propose

After generating the page, offer to:
- Adjust the player size (`#genymotion` width/height in CSS)
- Change `toolbarPosition` (`'left'` or `'right'`)
- Disable unused plugins (microphone, gamepad, phone…)
- Change the theme via CSS variables (`--gm-primary-color`, `--gm-background-color`)

### Reference

Full SDK documentation: `device-web-player-reference.md` (in this skill directory)
Template: `templates/device-web-player.html`

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
7. Display results clearly
8. Handle errors (show the message + suggest a solution)
```

---

## Tools Used

- `Bash` — to run `gmsaas` and `gmtool`
- `AskUserQuestion` — to disambiguate the platform and collect missing parameters
- `Read` — to read the reference files `gmsaas-reference.md`,`gmtool-reference.md`, `device-web-player-reference.md`
- `Glob` / `Read` — to locate local APK files or archives
