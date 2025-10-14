import AppKit
import WebKit

/// Borderless transparent always-on-top window hosting the WKWebView.
final class OverlayWindow: NSWindow {
    private var isInteractive = true
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .statusBar               // Above normal app windows but below screen saver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false // toggled later if click-through enabled
    }
    
    func updateInteractiveMode(_ interactive: Bool) {
        isInteractive = interactive
        if interactive {
            // Make window key so it can receive keyboard events
            makeKeyAndOrderFront(nil)
        } else {
            // Release key status in click-through mode
            resignKey()
        }
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }
}
