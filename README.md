# WebOverlay

WebOverlay is a lightweight macOS menu-bar app that renders transparent, always-on-top overlays of web pages (or solid colors) as HUDs. Manage a library of named pages and open each as its own overlay window — placed freely, one per monitor, or wherever you like — all from a status-bar menu. It also offers an optional password-protected fake lock screen for kiosk/demo use.

## Features
- **Menu-bar driven** — runs as a status-bar agent (no Dock icon). Open, manage, and configure overlays from the menu.
- **Page library** — save named URLs and open each as a separate always-on-top overlay (at most one window per page).
- **Per-window controls** — opacity slider, drag-to-move, monitor switching, reload, and close, all from the menu.
- **Multi-monitor aware** — each window remembers a preferred display and follows it across reconnects; reassign monitors on the fly.
- **Always-on-top** across all Spaces & full-screen (auxiliary) spaces, sitting just below the menu bar so the menu stays accessible.
- **Static color mode** — display a solid hex color instead of a web page.
- **Global settings** — click-through default, optional periodic auto-reload, and fake lock screen, edited in a Settings window.
- **Fake lock screen** — optional password-protected lock screen with a secure kiosk mode.
- **Hotkeys** — `Cmd+Option+Shift+O` toggles click-through for all windows; `Cmd+Option+Shift+K` quits.

## Getting Started

- Download the latest release from the [Releases](https://github.com/illixion/WebOverlay/releases) page, or build from source (see below).
- Move the app to your Applications folder. **Note:** macOS Quarantine may block the app on first launch; run the following if needed:
  ```bash
  xattr -d com.apple.quarantine /Applications/WebOverlay.app
  ```
- Launch the app. A 🟦 icon appears in the menu bar. On first run it seeds a default page and shows it as an overlay.
- Use the menu to add/open pages and adjust settings — there's no need to hand-edit the config file.

## Using the menu bar

Clicking the menu-bar icon opens a menu with:

- **Pages** — every saved page. Click one to open or close its overlay window (a checkmark marks open pages). Open pages expand to a submenu with:
  - **Opacity** — a live slider for that window.
  - **Movable (drag to move)** — toggle to reposition the window by dragging (forces the window interactive while on).
  - **Display** — move the window to a specific connected monitor.
  - **Reload** / **Close Window**.
- **Enable/Disable Interaction (all windows)** — global click-through toggle (same as `Cmd+Option+Shift+O`).
- **Manage Pages…** — add, rename, edit URLs, reorder, and delete saved pages.
- **Settings…** — edit global settings (below).
- **Quit WebOverlay**.

## Configuration

State is stored as the app's own data file at:
`~/Library/Application Support/WebOverlay/config.json`

You normally **don't edit this by hand** — use **Manage Pages…** and **Settings…**. The schema (`version: 2`):

```json
{
  "version": 2,
  "pages": [
    { "id": "…", "name": "Dashboard", "url": "https://example.com", "opacity": 0.3 }
  ],
  "globals": {
    "isClickThrough": true,
    "autoReloadInterval": 300,
    "color": null,
    "fakeLockScreen": null
  },
  "openWindows": [
    { "pageID": "…", "preferredDisplay": { "uuid": "…", "localizedName": "DELL U2720Q" } }
  ]
}
```

- **Pages** carry their own `opacity` (and an optional `color` for solid-color overlays instead of a `url`).
- **Globals** apply to all windows: `isClickThrough` (default click-through behavior), `autoReloadInterval` (seconds; null disables), `color` (legacy fallback), and `fakeLockScreen`.
- **openWindows** records which overlays are open and which monitor each prefers; this is restored on launch.

### Migration from older versions

An older single-overlay `config.json` (top-level `url`/`opacity`/`isClickThrough`/`color`/`fakeLockScreen`) is **migrated automatically** on first launch into one page plus global settings, and the file is rewritten in the `version: 2` format.

### Fake Lock Screen Mode

Configured under `globals.fakeLockScreen` (via the Settings window):

```json
{
  "globals": {
    "fakeLockScreen": {
      "enable": true,
      "password": "your-password",
      "message": "If found, please contact: email@example.com",
      "secure": true
    }
  }
}
```

When enabled, the app takes over as a lock screen:
- Displays a macOS-style lock screen with current time/date (built-in).
- Requires the correct password to exit (unlocking terminates the app).
- Shows an optional message at the bottom (e.g., contact info for lost devices).
- **Password security**: plaintext passwords are automatically hashed (SHA-256) and rewritten on save/launch.
- In secure mode (`secure: true`):
  - Disables the toggle and quit hotkeys.
  - Blocks system shortcuts (Cmd+Tab, Cmd+Space, Cmd+Opt+Esc, etc.) via CGEventTap.
  - Hides the Dock and menu bar.
  - Uses the screen-saver window level (appears above most system UI).
  - Covers all connected displays.
  - Requires Accessibility permission for full protection (prompted on launch).

This mode is useful for kiosk machines, demo setups, or anti-theft displays.

## Building

The repo includes an Xcode project. To build from the command line:

```bash
xcodebuild -project WebOverlay.xcodeproj -scheme WebOverlay -configuration Debug -destination 'platform=macOS' build
```

Notes for setting up the target:
- **App lifecycle**: SwiftUI `@main` (`OverlayApp.swift`) bridges to `AppDelegate` via `@NSApplicationDelegateAdaptor`. Keep `OverlayApp` as `@main`; do not mark `AppDelegate` with `@main`. The SwiftUI body is `Settings { EmptyView() }` — all overlay windows are created programmatically.
- **Menu-bar agent**: `LSUIElement` is set so there's no Dock icon. (The app temporarily becomes a regular app while a management window is open, then returns to agent mode.)
- **App Sandbox / Hardened Runtime are off** — required for Accessibility/CGEventTap (secure mode) and loading arbitrary URLs. If you hit signing errors, disable both in Signing & Capabilities.
- For non-HTTPS or self-signed content, add App Transport Security exceptions:
  ```xml
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  ```
- Deployment target: macOS 15.6.

## JavaScript API

WebOverlay injects a `window.__overlayControl` object into loaded pages, letting an overlay page control the app.

### Available Methods

**`window.__overlayControl.exit()`** — Terminates the WebOverlay application immediately.

```javascript
// Exit after 10 seconds
setTimeout(function() { window.__overlayControl.exit(); }, 10000);

// Exit on button click
document.getElementById('closeBtn').addEventListener('click', function() {
    window.__overlayControl.exit();
});
```

**`window.__overlayControl.verifyPassword(password)`** — *(Lock screen mode only)* Sends a password to WebOverlay for verification against the configured hash.
- If correct: tears down secure mode and terminates the app.
- If incorrect: calls `window.onPasswordIncorrect()` if defined.

```javascript
function unlock() {
    window.__overlayControl.verifyPassword(document.getElementById('passwordInput').value);
}
window.onPasswordIncorrect = function() {
    document.getElementById('error').textContent = 'Wrong password';
    document.getElementById('passwordInput').value = '';
};
```

**`window.__overlayControl.pause()`** — Pauses all timers and media. Used internally during sleep/screen lock.

**`window.__overlayControl.resume()`** — Resumes visibility. (The page is also reloaded on wake for reliability.)

### Page Visibility

When the overlay is hidden (display sleep or screen lock) WebOverlay drives the **standard Page Visibility API** so your page can idle backend polling/fetching while it isn't on screen. On hide it sets `document.hidden = true` / `document.visibilityState = "hidden"` and dispatches a real `visibilitychange` event (plus a `window` `blur`); on show it reverses this (plus a `focus`). A dedicated `overlayvisibilitychange` event is also dispatched on `document` with `event.detail.visible`.

```javascript
// Standard approach — works unchanged
document.addEventListener('visibilitychange', function() {
    if (document.hidden) stopPolling(); else startPolling();
});

// Or the explicit overlay event
document.addEventListener('overlayvisibilitychange', function(e) {
    e.detail.visible ? startPolling() : stopPolling();
});
```

## Source overview

- `OverlayApp.swift` — SwiftUI `@main` shell bridging to `AppDelegate`.
- `AppDelegate.swift` — App lifecycle, global hotkeys, secure-mode kiosk machinery, system observers.
- `OverlayManager.swift` — Owns the page library, global settings, open windows, persistence, and the lock-screen lifecycle.
- `OverlayWindowController.swift` / `OverlayWindow.swift` — One overlay window each (transparent, borderless, role-based level) and its state.
- `OverlayWebViewController.swift` — Hosts the `WKWebView` / color view / built-in lock screen and the JS bridge.
- `StatusItemController.swift` — The menu-bar status item and its dynamically-built menu.
- `ManagementWindows.swift` — The SwiftUI Manage Pages and Settings windows.
- `AppConfig.swift` — The `config.json` data model, legacy migration, and stable display identity.
- `OverlayConfig.swift` — Retained only as the decode-only DTO for migrating legacy configs.

## License
MIT
