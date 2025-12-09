# WebOverlay

This project is a lightweight macOS application written in Swift that creates a transparent, always-on-top overlay window displaying a specified web page as a HUD. It is designed to be simple and configurable via a JSON file.

## Features
- Always-on-top transparent window across all Spaces & full screen (auxiliary) spaces.
- Configurable URL, opacity, and click-through (mouse pass-through) behavior.
- Static color overlay mode – display a solid hex color instead of a webpage.
- Optional periodic auto-reload (URL mode only).
- Simple hotkey Command+Option+Shift+O toggles click-through.
- Ephemeral HUD feedback when toggling.

# Getting Started

- Download the latest release from the [Releases](https://github.com/illixion/WebOverlay/releases) page, or build from source (see below).
- Install the app by moving it to your Applications folder. **Note:** macOS Quarantine may block the app on first launch; run the following command in terminal if needed:
  ```bash
  xattr -d com.apple.quarantine /Applications/WebOverlay.app
  ```
- Launch the app; it will create a default config file if none exists.
- Edit the config file to customize the overlay (see Configuration section).

## File Overview
- `AppDelegate.swift` – App lifecycle, window setup, hotkey.
- `OverlayWindow.swift` – Transparent borderless window.
- `OverlayWebViewController.swift` – Hosts WKWebView, injects basic CSS to remove background.
- `OverlayConfig.swift` – Codable configuration (saved to `~/Library/Application Support/WebOverlay/config.json`).

## Configuration
Create (or let the app create) a JSON file at:
`~/Library/Application Support/WebOverlay/config.json`

### URL Mode (default)
Display a webpage as the overlay:
```json
{
  "url": "https://www.apple.com",
  "opacity": 0.85,
  "isClickThrough": true,
  "autoReloadInterval": 300
}
```

### Color Mode
Display a static solid color instead of a webpage:
```json
{
  "color": "#FF5500",
  "opacity": 0.5,
  "isClickThrough": true
}
```

Fields:
- `url` – Page to display (used when `color` is not set).
- `color` – Hex color string (e.g., `"#FF0000"`, `"FF0000"`, `"#F00"`, or `"F00"`). When set, displays a solid color overlay instead of a webpage.
- `opacity` – 0.0–1.0 window alpha.
- `isClickThrough` – If true, mouse events fall through to apps beneath.
- `autoReloadInterval` – Seconds between reloads (URL mode only; omit or null for disabled).

**Note:** If `color` is specified with a valid hex value, it takes precedence over `url`.

## Building

I've provided an Xcode project file for convenience, but you can also create your own project and add the source files.

1. In Xcode create a new macOS App target. You may choose either:
  - AppKit lifecycle (App Delegate) OR
  - SwiftUI lifecycle (recommended newer templates). This repo includes `OverlayApp.swift` which bridges to `AppDelegate` using `@NSApplicationDelegateAdaptor`.
2. If you used a SwiftUI template, keep `OverlayApp.swift` as `@main` and DO NOT mark `AppDelegate` with `@main`.
3. Remove any default storyboard / scene references; window creation is programmatic. Clear `NSMainStoryboardFile` if present.
4. Ensure `App Sandbox` is off (or allow outgoing network) if loading remote URLs.
5. If loading non-HTTPS or self-signed content, configure App Transport Security (ATS) exceptions in Info.plist:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsArbitraryLoads</key><true/>
   </dict>
   ```
6. To enable overlay on full-screen spaces, use LSUIElement setting, example is in `project.pbxproj`.
7. If you encounter errors after running the solution, try disabling App Sandbox and Hardened Runtime in Signing & Capabilities.

## Usage
- Launch the app; it loads the configured URL.
- Use Command+Option+Shift+O to toggle click-through vs interactive mode.
- Adjust opacity by editing the config and relaunching.
- Run `killall WebOverlay` to quit the app from terminal.

## JavaScript API
WebOverlay injects a `window.__overlayControl` object into all loaded webpages. This allows your overlay webpage to control the app.

### Available Methods

**`window.__overlayControl.exit()`**
Terminates the WebOverlay application.

```javascript
// Example: exit after 10 seconds
setTimeout(function() {
    window.__overlayControl.exit();
}, 10000);

// Example: exit on button click
document.getElementById('closeBtn').addEventListener('click', function() {
    window.__overlayControl.exit();
});
```

**`window.__overlayControl.pause()`**
Pauses all timers and media. Used internally during sleep/screen lock.

**`window.__overlayControl.resume()`**
Stub for resuming (reloading is used instead for reliability).

## Extending (Optional)
- Add a status bar item to expose a small menu (toggle, reload, quit).
- Live config reloading by watching the config file for changes.
- Add drag-to-move overlay region (currently uses full screen with `.stationary`). You could wrap the WKWebView in a custom NSView tracking events and reposition the window.
- Multi-overlay support: create multiple windows each with their own config. Currently, overlay spawns on the display where the app is launched.

## License
MIT
