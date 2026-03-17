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

## Should NOT trigger
- "How do I write an Android app?"
- "What is the best Android emulator?" (generic, no Genymotion mention)
- "How do I use ADB?" (no Genymotion mention)
- "Help me set up Docker"
- "How do I run Espresso tests?" (no Genymotion mention)
- "What is the best mobile testing framework?"

## Functional Test Cases

### Test 1 — Cloud: start instance + install APK
**User says**: "Start a Pixel 8 Pro on Genymotion Cloud and install my app.apk"

Expected behavior:
1. Platform detected: Cloud
2. `gmsaas` availability checked
3. `gmsaas recipes list` executed — user asked to pick one
4. `gmsaas instances start <recipe_uuid> <name> --max-run-duration <seconds>` executed
5. Status polled until ONLINE (up to 10 × 30s)
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
5. `--max-run-duration` recommended
6. `if: always()` stop step recommended
