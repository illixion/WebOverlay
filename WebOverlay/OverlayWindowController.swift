import AppKit

/// A transparent view placed above the web content that captures drags to move the window.
/// Only active (hit-testable) while window movement is enabled.
final class DragCatcherView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    // Don't draw anything; just intercept mouse events.
    override var isOpaque: Bool { false }
}

/// Owns a single overlay window: its OverlayWindow, its web view controller,
/// its page, preferred display, and movement/opacity state.
@MainActor
final class OverlayWindowController {
    private(set) var page: Page
    let window: OverlayWindow
    let viewController: OverlayWebViewController
    var preferredDisplay: DisplayRef?
    private(set) var isMovable: Bool

    private var dragCatcher: DragCatcherView?
    private var lastClickThrough: Bool
    private var autoReloadInterval: TimeInterval?

    init(page: Page,
         autoReloadInterval: TimeInterval?,
         unloadWhenHidden: Bool,
         preferredDisplay: DisplayRef?,
         isMovable: Bool,
         clickThrough: Bool,
         frame: NSRect) {
        self.page = page
        self.preferredDisplay = preferredDisplay
        self.isMovable = isMovable
        self.lastClickThrough = clickThrough
        self.autoReloadInterval = autoReloadInterval

        window = OverlayWindow(contentRect: frame, role: .page)
        viewController = OverlayWebViewController(content: .page(page, autoReloadInterval: autoReloadInterval, unloadWhenHidden: unloadWhenHidden))
        window.contentViewController = viewController
        window.alphaValue = page.opacity

        if isMovable {
            window.isMovable = true
            window.isMovableByWindowBackground = true
            installDragCatcher()
        }
        applyClickThrough(clickThrough)
    }

    // MARK: - Display placement

    func place(on screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
    }

    func show() {
        window.orderFront(nil)
        if !window.ignoresMouseEvents { window.bringToFront() }
    }

    func hide() { window.orderOut(nil) }

    func close() {
        viewController.pauseWebContent()
        window.orderOut(nil)
        window.contentViewController = nil
    }

    // MARK: - Interaction / movement

    /// Apply the global click-through setting. Movement forces the window interactive.
    func applyClickThrough(_ clickThrough: Bool) {
        lastClickThrough = clickThrough
        let effective = clickThrough && !isMovable
        window.ignoresMouseEvents = effective
        window.setInteractive(!effective)
    }

    func setMovable(_ on: Bool) {
        isMovable = on
        window.isMovable = on
        window.isMovableByWindowBackground = on
        if on { installDragCatcher() } else { removeDragCatcher() }
        applyClickThrough(lastClickThrough)
    }

    private func installDragCatcher() {
        guard dragCatcher == nil, let content = window.contentView else { return }
        let v = DragCatcherView(frame: content.bounds)
        v.autoresizingMask = [.width, .height]
        content.addSubview(v) // above the web view
        dragCatcher = v
    }

    private func removeDragCatcher() {
        dragCatcher?.removeFromSuperview()
        dragCatcher = nil
    }

    // MARK: - Page mutations

    func setOpacity(_ a: CGFloat) {
        page.opacity = a
        window.alphaValue = a
    }

    func reload() { viewController.load() }

    func pause() { viewController.pauseWebContent() }
    func resume() { viewController.resumeWebContent() }

    // MARK: - Persistence snapshot

    func currentState() -> OpenWindowState {
        OpenWindowState(pageID: page.id,
                        preferredDisplay: preferredDisplay,
                        frame: window.frame,
                        isMovable: isMovable)
    }
}
