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

The target device is specified with `-n <name>` or `--all` for all devices.

### ADB

```bash
gmtool device [-n <device>] adbconnect     # Connect via ADB
gmtool device [-n <device>] adbdisconnect  # Disconnect ADB
```

### Files and APKs

```bash
gmtool device [-n <device>] install <apk>                # Install an APK
gmtool device [-n <device>] push <source> <destination>  # Push a file
gmtool device [-n <device>] pull <source> <destination>  # Pull a file
gmtool device [-n <device>] flash <archive>              # Flash an archive
```

### Logs

```bash
gmtool device [-n <device>] logcatdump <file>  # Save logcat to file
gmtool device [-n <device>] logcatclear        # Clear logcat
```

### Additional options

```
--all      Target all running devices
--start    Automatically start the device if it is stopped
```

---

## Common Workflows

### Start a device and install an APK

```bash
# 1. List available devices
gmtool admin list

# 2. Start the device
gmtool admin start "Pixel 7 API 33"

# 3. Install the APK (ADB connects automatically on start)
gmtool device -n "Pixel 7 API 33" install app.apk
```

### Create a custom device

```bash
# 1. List available profiles and images
gmtool admin hwprofiles
gmtool admin osimages

# 2. Create the device
gmtool admin create "Custom Phone" "Android 14.0" "My Device" \
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
gmtool device -n "My Device" logcatdump ~/debug.log
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
