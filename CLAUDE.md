# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WebOverlay is a macOS menu-bar agent (`LSUIElement=YES`, no Dock icon) that renders transparent, always-on-top web overlays. It started as a single hardcoded overlay and was refactored into a multi-window page manager driven from a status-bar menu. The app is AppKit-centric with a thin SwiftUI shell.

## Build & run

```bash
# Build (scheme is auto-created; no shared scheme is checked in)
xcodebuild -project WebOverlay.xcodeproj -scheme WebOverlay -configuration Debug -destination 'platform=macOS' build

# Run the built product
open ~/Library/Developer/Xcode/DerivedData/WebOverlay-*/Build/Products/Debug/WebOverlay.app

# Quit (it's a menu-bar agent, no Dock icon / Cmd-Q)
pkill -f WebOverlay.app
```

- There is **no test target** — verification is manual (launch, exercise the menu).
- Deployment target is **macOS 15.6** (the project-level 26.0 is overridden at the target level). Swift 5, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- App Sandbox and Hardened Runtime are **off** (needed for Accessibility / CGEventTap in secure mode and arbitrary URL loads).
- Source files are picked up via Xcode **file-system-synchronized groups** — new `.swift` files under `WebOverlay/` are compiled automatically with no `project.pbxproj` edit.

## Architecture

The app is a hierarchy of single-responsibility objects, all `@MainActor`. Data flows top-down from a persisted store; the menu and settings windows are views over it.

- **OverlayApp.swift** — `@main` SwiftUI `App` whose only job is `@NSApplicationDelegateAdaptor` → `AppDelegate`. Body is `Settings { EmptyView() }`; **do not** add `WindowGroup`/`Window` scenes (they would create restorable windows and fight the agent lifecycle — management windows are created on demand instead).

- **AppDelegate.swift** — Shrunk to OS-level concerns only: owns the `OverlayManager` and `StatusItemController`, registers Carbon global hotkeys (`Cmd+Opt+Shift+O` → toggle global click-through, `Cmd+Opt+Shift+K` → quit), and implements `SecureModeHost` (the CGEventTap key-blocker, kiosk presentation options, accessibility prompt, and NSEvent-monitor fallback). Observes sleep/wake, screen lock/unlock, and `didChangeScreenParametersNotification`, forwarding each to the manager. It owns **no windows**.

- **OverlayManager.swift** — The brain (`ObservableObject`). Owns the page library (`@Published pages`), `@Published globals`, and a `[UUID: OverlayWindowController]` keyed by page id (this dictionary *is* the "≤1 window per page" invariant). Handles open/close/toggle, opacity, movement, monitor reassignment, persistence (debounced ~0.5s), display-change repositioning (debounced ~0.3s), and the secure lock lifecycle. Mutations rebuild `openWindows` and call `persist()`.

- **OverlayWindowController.swift** — Owns one `OverlayWindow` + one `OverlayWebViewController` + per-window state (page, preferred display, movable flag). Applies click-through and hosts the `DragCatcherView` (a transparent top view that calls `performDrag` — needed because the WKWebView eats background drags).

- **OverlayWindow.swift** — Borderless transparent `NSWindow` with a `Role` (`page` / `lock` / `blackout`). Role decides window level and collection behavior: page windows sit just **below the menu bar** (`mainMenu - 1`) so the status item stays clickable, and omit `.stationary` so they're draggable; lock/blackout use `.screenSaver` + `.stationary`.

- **OverlayWebViewController.swift** — Renders an `OverlayContent` enum: `.page(Page, autoReloadInterval:)` (WKWebView or solid color) or `.lockScreen(GlobalSettings)` (built-in lock-screen HTML). Bridges `window.__overlayControl` JS (exit / verifyPassword / pause-resume). On unlock it calls `onUnlockSuccess` (set by the manager) which tears down secure mode and terminates.

- **StatusItemController.swift** — The `NSStatusItem` + `NSMenu` (`NSMenuDelegate`). The menu is **rebuilt on every open** in `menuNeedsUpdate` from manager state (plain `NSMenu`, not `MenuBarExtra`, so it can host the `OpacitySliderItemView` custom-view slider). Open pages show a checkmark and a per-window submenu (opacity, movable, display switch, reload, close).

- **ManagementWindows.swift** — `WindowPresenter` opens the SwiftUI **Manage Pages** and **Settings** windows on demand via `NSHostingController`. Critical detail: an `.accessory` app's windows won't take keyboard focus, so the presenter flips `NSApp.setActivationPolicy(.regular)` on open and back to `.accessory` once the last management window closes (`windowWillClose`).

### Data model & persistence — AppConfig.swift

`config.json` lives at `~/Library/Application Support/WebOverlay/config.json` and is **the app's own data store** (`version: 2`):
- `pages: [Page]` — `{id, name, url, color?, opacity}`. **Opacity is per-page**; everything else is global.
- `globals: GlobalSettings` — `isClickThrough` (global, default true), `autoReloadInterval`, fallback `color`, `fakeLockScreen`.
- `openWindows: [OpenWindowState]` — restored on launch.

`AppConfig.load` migrates the **legacy single-overlay format** (detected by absence of a `pages` key) into one page + globals + one open window, then writes back v2. `OverlayConfig.swift` is retained **only as the decode-only migration DTO** — don't build new features on it.

Displays are persisted by **`CGDisplayCreateUUIDFromDisplayID`** (in `DisplayRef.uuid`), not `NSScreenNumber`/`CGDirectDisplayID` (which are reassigned across reconnects). See the `NSScreen` extension (`displayUUID`, `screen(matching:)`).

### Secure lock screen

A global mode (toggled in Settings, `globals.fakeLockScreen`). When active it's a takeover: page windows are hidden, a lock window covers the main screen, blackout windows cover the others, and `SecureModeHost` engages the kiosk machinery. **Unlock terminates the app** (intentional — it's effectively an exclusive run). Hotkeys are not registered while secure.

## Conventions

- Everything UI/window-related is `@MainActor`; keep it that way.
- The README still documents the pre-refactor single-overlay config format and file list — treat it as historical for the data model, not current.
- Logging uses `NSLog("[Overlay] …")`.
