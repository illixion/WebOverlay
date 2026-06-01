import AppKit
import WebKit

/// Borderless transparent always-on-top window hosting overlay content.
final class OverlayWindow: NSWindow {
    /// What this window is for — affects level and collection behavior.
    enum Role {
        case page       // a normal user overlay (movable, can join all spaces)
        case lock       // the secure lock-screen takeover
        case blackout   // a black cover on a secondary display during secure lock
    }

    let role: Role
    private var isInteractive = true

    init(contentRect: NSRect, role: Role = .page) {
        self.role = role
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false

        switch role {
        case .lock, .blackout:
            // Above Force Quit, Notification Center, etc.
            level = .screenSaver
            // Pin to its Space so it can't be scrolled away during a lock.
            collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        case .page:
            // Just below the system menu bar so the menu bar (and our status item)
            // stay clickable even when the overlay is interactive, while still
            // floating above all normal app windows.
            level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            // No .stationary so the window can be dragged / moved across Spaces.
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false // toggled later if click-through enabled
    }

    /// Allow/deny becoming key (keyboard focus) without forcing window ordering.
    func setInteractive(_ interactive: Bool) {
        isInteractive = interactive
        if !interactive {
            resignKey()
        }
    }

    /// Bring the window forward and make it key (only effective if interactive).
    func bringToFront() {
        makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }
}
