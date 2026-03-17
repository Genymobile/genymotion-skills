# Genymotion Device Web Player — Reference

Reference for the `@genymotion/device-web-player` SDK, which embeds a running Genymotion Cloud instance directly into a web page via WebRTC.

---

## Prerequisites

- A Genymotion Cloud instance **already started** (via `gmsaas` or the SaaS dashboard)
- A **Genymotion API token** to call the Cloud REST API (generate one at https://cloud.geny.io/app/api-tokens)

---

## Getting the WebRTC Address and Access Token

> **Security notice**: API tokens and access tokens are sensitive credentials.
> Run the commands below **in your own terminal** — never paste them into an AI chat or share them.
> Edit the HTML file directly to set the values.

Both values must be retrieved via the Genymotion Cloud REST API before initialising the player.
You will need a **Genymotion API token** from https://cloud.geny.io/app/api-tokens.

### 1. Get the WebRTC address

Run in your terminal:

```bash
curl -H 'Content-Type: application/json;charset=utf-8' \
     -H 'x-api-token: <YOUR_API_TOKEN>' \
     https://api.geny.io/cloud/v1/instances/<INSTANCE_UUID>
```

Extract the `webrtc_url` field from the JSON response:

```json
{
  "webrtc_url": "wss://...",
  ...
}
```

That value is the `webrtcAddress` to pass to the player.

### 2. Get the player access token

The player requires a **short-lived access token** (different from the API token).
Run in your terminal:

```bash
curl -X POST \
     -H 'Content-Type: application/json;charset=utf-8' \
     -H 'x-api-token: <YOUR_API_TOKEN>' \
     -d '{"instance_uuid": "<INSTANCE_UUID>"}' \
     https://api.geny.io/cloud/v1/instances/access-token
```

Use the returned token as the `token` option when initialising the player.

### 3. Edit the HTML template

Open the generated HTML file and replace the two constants at the top of the `<script>` block:

```javascript
const WEBRTC_ADDRESS = 'wss://...';   // ← paste the webrtc_url here
const AUTH_TOKEN     = '...';         // ← paste the access token here
```

Do this edit directly in your editor — never share these values in a chat.

---

## Installation

### Via CDN (no build step required)

```html
<link rel="stylesheet"
      href="https://cdn.jsdelivr.net/npm/@genymotion/device-web-player@4.2.1/dist/css/device-renderer.min.css" />
<script src="https://cdn.jsdelivr.net/npm/@genymotion/device-web-player@4.2.1/dist/js/device-renderer.min.js"></script>
```

### Via npm / yarn

```bash
npm install @genymotion/device-web-player
# or
yarn add @genymotion/device-web-player
```

```javascript
const { DeviceRendererFactory } = require('@genymotion/device-web-player');
import '@genymotion/device-web-player/dist/css/device-renderer.min.css';
```

---

## Basic Usage

```javascript
const { DeviceRendererFactory } = window.genyDeviceWebPlayer;

const container = document.getElementById('genymotion');
const webrtcAddress = 'wss://<instance-ip>';

const options = {
    token: 'YOUR_AUTH_TOKEN',
    showPhoneBorder: true,
    toolbarPosition: 'right',   // 'left' | 'right'
    floatingToolbar: true,
};

const factory = new DeviceRendererFactory();
const renderer = factory.setupRenderer(container, webrtcAddress, options);

// Cleanup on page unload
window.addEventListener('beforeunload', () => renderer.disconnect());
```

---

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `token` | String | — | **Required.** Auth token from the SaaS dashboard |
| `showPhoneBorder` | Boolean | `false` | Display a smartphone frame around the device |
| `toolbarPosition` | String | `"right"` | Toolbar side: `"left"` or `"right"` |
| `floatingToolbar` | Boolean | `true` | Show the floating control toolbar |
| `connectionFailedURL` | String | — | Redirect URL on connection failure |
| `fileUpload` | Boolean | `false` | Enable drag-and-drop APK/file install |
| `fileUploadUrl` | String | — | Endpoint to handle file uploads |
| `i18n` | Object | `{}` | Override UI text labels |

---

## Plugin Toggles

Add these keys to `options` to enable/disable features (all default to `true` unless noted):

| Plugin | Default | Description |
|--------|---------|-------------|
| `battery` | `true` | Battery level & charging control |
| `biometrics` | `true` | Fingerprint authentication |
| `camera` | `true` | Webcam forwarding to device |
| `clipboard` | `true` | Copy-paste between host and device |
| `capture` | `true` | Screenshots and screen recording |
| `gps` | `true` | Location control with map |
| `gamepad` | `true` | Virtual controller |
| `keyboardMapping` | `true` | Custom key-to-action mapping |
| `microphone` | `false` | Audio input forwarding |
| `network` | `true` | WiFi/cellular configuration |
| `phone` | `true` | SMS and call simulation |
| `power` | `true` | Reboot controls |
| `rotation` | `true` | Screen orientation |
| `streamResolution` | `true` | Video quality adjustment (SaaS only) |
| `streamBitrate` | `true` | Bitrate control (SaaS only) |

Example — disable unused plugins:

```javascript
const options = {
    token: 'YOUR_AUTH_TOKEN',
    microphone: false,
    gamepad: false,
    phone: false,
};
```

---

## API Methods

```javascript
renderer.disconnect()                          // Disconnect & free resources
renderer.mute()                               // Mute device audio
renderer.unmute()                             // Unmute device audio
renderer.fullscreen()                         // Enter fullscreen (requires user gesture)
renderer.openWidget('battery')               // Programmatically open a widget
renderer.closeWidget('battery')              // Programmatically close a widget
renderer.addEventListener('event', callback) // Listen to device events
renderer.sendData({ channel, messages })     // Send data to the device
```

---

## Custom Styling (CSS Variables)

Override any of the following CSS variables on `:root` (or a parent element) to theme the player UI.

### Color tokens

```css
:root {
    /* Primary — main accent (buttons, active states) */
    --gm-primary-color:             rgba(230, 25, 94, 1);
    --gm-on-primary-color:          rgba(255, 255, 255, 1);
    --gm-primary-variant-color:     rgba(230, 25, 94, 0.2);
    --gm-on-primary-variant-color:  rgba(230, 25, 94, 1);

    /* Secondary — secondary UI elements */
    --gm-secondary-color:           #ffffff;
    --gm-on-secondary-color:        #292929;
    --gm-secondary-variant-color:   #f7f7ff;
    --gm-on-secondary-variant-color:#1a1a1a;

    /* Tertiary — borders, dividers, tertiary controls */
    --gm-tertiary-color:            #c4c4c44d;
    --gm-on-tertiary-color:         #1a1a1a;
    --gm-tertiary-variant-color:    #c4c4c4;
    --gm-on-tertiary-variant-color: #1a1a1a;

    /* Background & surface */
    --gm-background-color:          #e7e7f3;
    --gm-on-background-color:       #1a1a1a;
    --gm-surface-color:             #f7f7f7;
    --gm-on-surface-color:          #1a1a1a;

    /* Semantic states */
    --gm-error-color:                rgba(255, 17, 17, 1);
    --gm-background-error-color:     rgba(255, 17, 17, 0.1);
    --gm-success-color:              rgba(17, 185, 32, 1);
    --gm-background-success-color:   rgba(17, 185, 32, 0.1);
    --gm-warning-color:              rgba(255, 204, 0, 1);
    --gm-background-warning-color:   rgba(255, 204, 0, 0.1);

    /* Gradients */
    --gm-gradient-1:                 linear-gradient(142.33deg, #e6195e 4.58%, #2b41ea 122.31%);
    --gm-on-gradient-1:              rgba(255, 255, 255, 1);
    --gm-gradient-2:                 linear-gradient(275.69deg, #e6195e 10.31%, #2b41ea 136.09%);
    --gm-on-gradient-2:              rgba(255, 255, 255, 1);
}
```

---

## Browser Compatibility

| Browser | Minimum version |
|---------|----------------|
| Chrome | 85+ |
| Firefox | 78+ |
| Edge | 20.10240+ |
| Opera | 70+ |
| Safari | 11+ |

---

## Template

A ready-to-use HTML page is available in `templates/device-web-player.html`.
Open it, fill in `WEBRTC_ADDRESS` and `AUTH_TOKEN`, and serve it with any static server.

```bash
# Quick local server
npx serve .
# or
python3 -m http.server 8080
```
