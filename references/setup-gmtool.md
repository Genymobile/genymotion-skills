# gmtool Installation & Setup

gmtool is bundled with Genymotion Desktop.

## Linux

```bash
# Download from https://www.genymotion.com/product-desktop/
chmod +x genymotion-*.bin && ./genymotion-*.bin

# Add to PATH (current session):
export PATH="$PATH:/opt/genymobile/genymotion"

# Add to PATH permanently — append to ~/.bashrc or ~/.zshrc:
echo 'export PATH="$PATH:/opt/genymobile/genymotion"' >> ~/.bashrc
```

## macOS

```bash
# Download the .dmg from https://www.genymotion.com/product-desktop/
# Drag Genymotion into Applications, then add to PATH:
export PATH="$PATH:/Applications/Genymotion.app/Contents/MacOS"

# Permanently:
echo 'export PATH="$PATH:/Applications/Genymotion.app/Contents/MacOS"' >> ~/.zshrc
```

## Windows (PowerShell)

```powershell
# Download and run the .exe installer from https://www.genymotion.com/product-desktop/
# gmtool.exe will be in: C:\Program Files\Genymobile\Genymotion

# Add to PATH for current session:
$env:PATH += ";C:\Program Files\Genymobile\Genymotion"

# Add to PATH permanently (run as Administrator):
[Environment]::SetEnvironmentVariable(
  "PATH",
  $env:PATH + ";C:\Program Files\Genymobile\Genymotion",
  "Machine"
)
```

---

## Verify installation

```bash
gmtool version
```

---

## Post-install configuration

```bash
# Set your Genymotion account credentials:
gmtool config --email <your_email>
gmtool config --password <your_password>

# Register your licence key:
gmtool license register <your_licence_key>

# Verify licence status:
gmtool license info
```

> **Note**: A valid licence (Indie or Business) is required for most gmtool commands.
> Exit code 9 means the licence is not activated — run `gmtool license info` to diagnose.
