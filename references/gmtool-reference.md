# Genymotion Desktop — gmtool Reference

Complete reference for `gmtool` commands to manage local Genymotion Desktop devices.

---

## Prerequisites

- Genymotion Desktop installed (Windows, macOS, or Linux)
- `gmtool` available in PATH (bundled with Genymotion Desktop)
- Valid Genymotion licence (Indie or Business for some features)

### Verify the installation

```bash
gmtool version
```

### Add gmtool to PATH (if not found)

```bash
# Linux
export PATH="$PATH:/opt/genymobile/genymotion"

# macOS
export PATH="$PATH:/Applications/Genymotion.app/Contents/MacOS"

# Windows (PowerShell)
$env:PATH += ";C:\Program Files\Genymobile\Genymotion"
```

---

## Global Options

| Option | Short | Description |
|--------|-------|-------------|
| `--timeout <seconds>` | `-t` | Timeout 0-3600s |
| `--verbose` | `-v` | Verbose output |
| `--help` | `-h` | Show help |

---

## Commands — Version

```bash
gmtool version
```

---

## Commands — Licence

```bash
gmtool license info                  # Show active licence information
gmtool license register <key>        # Register a licence key
gmtool license count                 # Number of activated seats
gmtool license validity              # Days remaining on the licence
```

---

## Commands — Config

```bash
gmtool config --email <email>
gmtool config --password <password>
gmtool config --virtual_device_path <path>
gmtool config --use_custom_sdk <on|off>
gmtool config --sdk_path <path>
gmtool config --screen_capture_path <path>
gmtool config --proxy <on|off>
gmtool config --proxy_type <http|socks5>
gmtool config --proxy_address <url>
gmtool config --proxy_port <port>
gmtool config --proxy_auth <on|off>
gmtool config --proxy_username <username>
gmtool config --proxy_password <password>
gmtool config --shared_clipboard <on|off>
gmtool config --hypervisor <virtualbox|qemu>
gmtool config --statistics <on|off>
```

---

## Commands — Admin (Device Management)

### List devices

```bash
gmtool admin list              # All devices
gmtool admin list --running    # Running devices only
gmtool admin list --off        # Stopped devices only
```

### Start / Stop

```bash
gmtool admin start <device>            # Start a device
gmtool admin start <device> --coldboot # Start with cold boot (QEMU)
gmtool admin stop <device>             # Stop a device
gmtool admin stopall                   # Stop all devices
```

### Details

```bash
gmtool admin details           # Details of all devices
gmtool admin details <device>  # Details of a specific device
```

### Create a device

```bash
gmtool admin create <hwprofile> <osimage> <name> [OPTIONS]
# Options:
#   --width <px>                Screen width
#   --height <px>               Screen height
#   --density <dpi>             Density (120-640)
#   --nbcpu <n>                 Number of CPUs
#   --ram <mb>                  RAM in MB
#   --navbar <on|off>           Navigation bar
#   --virtualkeyboard <on|off>
#   --root-access <on|off>
#   --quickboot <on|off>        QEMU only
#   --network-mode <nat|bridge> VirtualBox only
#   --sysprop <prop>:<value>    System properties
```

### Edit a device

```bash
gmtool admin edit <device> [OPTIONS]   # Same options as create
```

### Other operations

```bash
gmtool admin clone <device> <new_name>    # Clone a device
gmtool admin factoryreset <device>        # Factory reset a device
gmtool admin delete <device>              # Delete a device
gmtool admin logzip <path>                # Export all logs
gmtool admin logzip -n <device> <path>    # Logs for a specific device
```

### Available resources

```bash
gmtool admin hwprofiles   # List available hardware profiles
gmtool admin osimages     # List available OS images
```

---

## Commands — Device (Operations on a running device)

The target device is specified with `-n <name>` (placed **after** the subcommand) or `--all` for all devices.

> **Important**: The `-n` flag and `--all` come **after** the subcommand name, not before it.
> Correct: `gmtool device logcatdump -n 'My Device' dump.log`
> Wrong:   `gmtool device -n 'My Device' logcatdump dump.log`

### ADB

```bash
gmtool device adbconnect "<device>"     # Connect via ADB (device name is positional)
gmtool device adbdisconnect "<device>"  # Disconnect ADB
```

> **Note**: With Genymotion Desktop, ADB connects automatically when a device starts. `adbconnect` is only needed if the connection was lost.

### Files and APKs

```bash
gmtool device install -n <device> <apk>                # Install an APK
gmtool device push -n <device> <source> <destination>  # Push a file
gmtool device pull -n <device> <source> <destination>  # Pull a file
gmtool device flash -n <device> <archive>              # Flash an archive

# Target all running devices
gmtool device install --all <apk>
```

### Logs

```bash
gmtool device logcatdump -n <device> <file>  # Save logcat to file
gmtool device logcatclear -n <device>        # Clear logcat
```

### Additional options

```
-n <name>  Target a specific device (placed after the subcommand)
--all      Target all running devices
--start    Automatically start the device if it is stopped
```

---

## Common Workflows

### Launch a device (start or create + start)

**Always check if the device already exists before creating it.**

```bash
# 1. Check if the device already exists
gmtool admin list
```

- If the device is listed → go directly to step 3 (start it).
- If the device is **not** listed → create it first (step 2), then start it (step 3).

```bash
# 2. (Only if the device does not exist) Find the right hwprofile and osimage, then create
gmtool admin hwprofiles | grep -i "<hardware keyword>"
gmtool admin osimages   | grep -i "<android version>"
gmtool admin create <hwprofile_uuid> <osimage_uuid> "<Device Name>"

# 3. Start the device
gmtool admin start "<Device Name>"
```

### Start a device and install an APK

```bash
# 1. Check if the device exists
gmtool admin list

# 2. Start the device (skip if already running — State = On)
gmtool admin start "Pixel 7 API 33"

# 3. Install the APK (ADB connects automatically on start)
gmtool device install -n "Pixel 7 API 33" app.apk
```

### Create a custom device

```bash
# 1. List available profiles and images
gmtool admin hwprofiles
gmtool admin osimages

# 2. Create the device
gmtool admin create <hwprofile_uuid> <osimage_uuid> "My Device" \
  --width 1080 --height 2400 --density 428 \
  --nbcpu 4 --ram 4096 --root-access on
```

### Clone and modify an existing device

```bash
gmtool admin clone "My Device" "My Device - Test"
gmtool admin edit "My Device - Test" --ram 8192 --nbcpu 8
```

### Debug with logs

```bash
gmtool device logcatdump -n "My Device" ~/debug.log
gmtool admin logzip ~/genymotion-logs.zip -n "My Device"
```

---

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| 1 | Unknown command | Check the syntax |
| 2 | Invalid parameter value | Fix the value |
| 3 | Command failed | Check logs with `logzip` |
| 4 | Virtualisation engine not responding | Restart Genymotion Desktop |
| 5 | Device not found | Run `gmtool admin list` |
| 6 | Unable to connect | Check email/password in config |
| 9 | Licence not activated | Run `gmtool license info` |
| 10 | Invalid licence key | Check the key |
| 13 | Unable to start device | Check system resources |
| 14 | Requires Indie/Business licence | Upgrade the licence |
