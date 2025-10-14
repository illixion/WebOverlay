# WebOverlay

This project is a lightweight macOS application written in Swift that creates a transparent, always-on-top overlay window displaying a specified web page as a HUD. It is designed to be simple and configurable via a JSON file.

## Features
- Always-on-top transparent window across all Spaces & full screen (auxiliary) spaces.
- Configurable URL, opacity, and click-through (mouse pass-through) behavior.
- Optional periodic auto-reload.
- Simple hotkey Command+Option+Shift+O toggles click-through.
- Ephemeral HUD feedback when toggling.

## File Overview
- `AppDelegate.swift` – App lifecycle, window setup, hotkey.
- `OverlayWindow.swift` – Transparent borderless window.
- `OverlayWebViewController.swift` – Hosts WKWebView, injects basic CSS to remove background.
- `OverlayConfig.swift` – Codable configuration (saved to `~/Library/Application Support/SwiftOverlay/config.json`).

## Configuration
Create (or let the app create) a JSON file at:
`~/Library/Application Support/SwiftOverlay/config.json`

Example:
```json
{
  "url": "https://www.apple.com",
  "opacity": 0.85,
  "isClickThrough": true,
  "autoReloadInterval": 300
}
```

Fields:
- `url` – Page to display.
- `opacity` – 0.0–1.0 window alpha.
- `isClickThrough` – If true, mouse events fall through to apps beneath.
- `autoReloadInterval` – Seconds between reloads (omit or null for disabled).

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
- Adjust opacity by editing the config and relaunching (or extend code to watch the file if desired).

## Extending (Optional)
- Add a status bar item to expose a small menu (toggle, reload, quit).
- Add drag-to-move overlay region (currently uses full screen). You could wrap the WKWebView in a custom NSView tracking events and reposition the window.
- Multi-overlay support: create multiple windows each with their own config.

## License
MIT
