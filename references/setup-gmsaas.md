# gmsaas Installation & Setup

## Install

### Linux / macOS

```bash
# Recommended — virtualenv:
python3 -m venv .venv && source .venv/bin/activate && pip install gmsaas

# Or globally:
pip3 install gmsaas
# If you get an "externally-managed-environment" error:
pip3 install gmsaas --break-system-packages
```

### Windows (PowerShell)

```powershell
# Recommended — virtualenv:
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install gmsaas

# Or globally:
pip install gmsaas
```

> **Note**: On Windows, use `python` instead of `python3`, and `.venv\Scripts\gmsaas` instead of `.venv/bin/gmsaas` when calling gmsaas from a venv.

---

## Configure — Android SDK path

Required for ADB operations. Use the path matching your setup:

| OS | Common SDK path |
|----|----------------|
| Linux | `~/Android/Sdk` |
| macOS | `~/Library/Android/sdk` |
| Windows | `%LOCALAPPDATA%\Android\Sdk` |

```bash
# Linux / macOS:
gmsaas config set android-sdk-path ~/Android/Sdk

# Windows (PowerShell):
gmsaas config set android-sdk-path "$env:LOCALAPPDATA\Android\Sdk"
```

---

## Authenticate

> ⚠️ **Security**: Never share your API token or commit it to source control.
> Prefer the environment variable method over the CLI command,
> as CLI arguments can be exposed in shell history.

```bash
# Linux / macOS — environment variable (preferred):
export GENYMOTION_API_TOKEN="your_token"

# Windows (PowerShell) — environment variable (preferred):
$env:GENYMOTION_API_TOKEN = "your_token"

# CLI fallback (avoid — exposes token in shell history):
gmsaas auth token <your_token>
```

Generate a token at: https://cloud.geny.io/api

---

## Verify

```bash
gmsaas doctor
```
