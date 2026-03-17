# Genymotion Cloud — gmsaas Reference

Complete reference for `gmsaas` commands to manage Genymotion Cloud instances.

---

## Setup & Configuration

### Install gmsaas

```bash
pip3 install gmsaas
# If you get an "externally-managed-environment" error:
pip3 install gmsaas --break-system-packages
```

### Set the Android SDK path

```bash
gmsaas config set android-sdk-path <path_to_sdk>
```

### Authenticate

```bash
# Via token (get one from https://cloud.geny.io/api)
gmsaas auth token <your_token>

# Via environment variable (no login command needed)
export GENYMOTION_API_TOKEN="your_token"

# Reset auth
gmsaas auth reset
```

### Verify the setup

```bash
gmsaas doctor   # Returns exit code 0 if everything is OK
```

### Output format

```bash
gmsaas config set output-format json        # json | text | compactjson
gmsaas --format json <command>             # For a single command
```

---

## Global Options

| Option | Description |
|--------|-------------|
| `--format json` | JSON output for a command |
| `--help` / `-h` | Help for any command |

---

## Commands — Auth

```bash
gmsaas auth token <token>   # Authenticate with an API token
gmsaas auth reset            # Reset authentication
```

---

## Commands — Config

```bash
gmsaas config set android-sdk-path <path>
gmsaas config set output-format <text|json|compactjson>
gmsaas config set proxy <proxy_url>
```

---

## Commands — Instances

```bash
# List all active instances
gmsaas instances list [-q]

# Get details of an instance
gmsaas instances get <instance_uuid>

# Start an instance from a recipe
gmsaas instances start <recipe_uuid> <name> [--no-wait] [--max-run-duration <seconds>]

# Stop an instance
gmsaas instances stop <instance_uuid> [--no-wait]

# Connect to ADB
gmsaas instances adbconnect <instance_uuid> [--adb-serial-port <port>]

# Open the instance display
gmsaas instances display [<instance_uuid> ...] [--yes]

# Save instance state (overwrites the current OS image)
gmsaas instances save <instance_uuid>

# Save as a new recipe
gmsaas instances saveas <instance_uuid> --osimage-name <name> --recipe-name <name>
```

---

## Commands — Recipes

```bash
# List recipes
gmsaas recipes list [--name <filter>] [--source all|official|custom]

# Get details of a recipe
gmsaas recipes get <recipe_uuid>

# Create a recipe (hwprofile + osimage)
gmsaas recipes create <hwprofile_uuid> <osimage_uuid> <name>

# Delete a recipe
gmsaas recipes delete <recipe_uuid> [--delete-osimage] [--delete-hwprofile]
```

---

## Commands — OS Images

```bash
gmsaas osimages list
gmsaas osimages get <osimage_uuid>
gmsaas osimages clone <base_osimage_uuid> <name>
gmsaas osimages delete <osimage_uuid>
```

---

## Commands — Hardware Profiles

```bash
gmsaas hwprofiles list
gmsaas hwprofiles get <hwprofile_uuid>
gmsaas hwprofiles create <name> \
  [--width <px>] [--height <px>] [--density <dpi>] \
  [--form-factor <type>] [--navigation-bar]
gmsaas hwprofiles delete <hwprofile_uuid>
```

---

## Commands — Display

Open a running cloud instance (copies the link to clipboard and may open it in the browser):

```bash
gmsaas instances display <instance_uuid>
```

Or open directly in the Genymotion Cloud web interface:

```
https://cloud.geny.io/instance/<instance_uuid>
```

> The user must be logged in to https://cloud.geny.io beforehand.

---

## Commands — ADB daemon

```bash
gmsaas adb start   # Start the ADB daemon
gmsaas adb stop    # Stop the ADB daemon
```

---

## Common Workflows

### Start an instance and connect ADB

```bash
# 1. Choose a recipe
gmsaas recipes list

# 2. Start the instance (always set a max duration to avoid unexpected charges)
gmsaas instances start <recipe_uuid> "my-instance" --max-run-duration 3600

# 3. Connect ADB
gmsaas instances adbconnect <instance_uuid>

# 4. Use ADB normally
adb devices
```

### Run automated tests

```bash
# 1. Start the instance (set duration to match your expected test time)
gmsaas instances start <recipe_uuid> "test-device" --max-run-duration 3600

# 2. Connect ADB
gmsaas instances adbconnect <instance_uuid>

# 3. Run tests
./gradlew connectedAndroidTest

# 4. Stop the instance after tests
gmsaas instances stop <instance_uuid>
```

### Start an instance and display it

```bash
# 1. Start the instance
gmsaas instances start <recipe_uuid> "my-instance" --max-run-duration 3600

# 2. Get the instance UUID
gmsaas instances list

# 3. Display (copies link to clipboard)
gmsaas instances display <instance_uuid>
# Or open directly: https://cloud.geny.io/instance/<instance_uuid>
```

### Save an instance as a new recipe

```bash
gmsaas instances saveas <instance_uuid> \
  --osimage-name "my-custom-image" \
  --recipe-name "my-custom-recipe"
```

---

## Error Handling

| Situation | Action |
|-----------|--------|
| `gmsaas` not found | Check PATH or provide venv path (see SKILL.md) |
| Auth error / 401 | `gmsaas auth token <token>` or check `GENYMOTION_API_TOKEN` |
| Unknown UUID | Run the corresponding `list` command and ask the user |
| Instance already started/stopped | Inform the user of the current state |
| `adb devices` empty after `adbconnect` | Run `gmsaas adb start` to start the local ADB daemon, then retry |
| `gmsaas doctor` fails | Go through each check (SDK path, auth, network) |
