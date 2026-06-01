import AppKit
import Combine

/// Implemented by AppDelegate to own the OS-level secure-mode machinery
/// (CGEventTap key blocking, presentation/kiosk options, accessibility checks).
@MainActor
protocol SecureModeHost: AnyObject {
    func engageSecureKiosk()
    func disengageSecureKiosk()
}

/// Owns the page library, global settings, and the set of open overlay windows
/// (at most one per page). Handles persistence, display changes, and the secure
/// lock-screen lifecycle.
@MainActor
final class OverlayManager: ObservableObject {
    @Published var pages: [Page]
    @Published var globals: GlobalSettings

    private var controllers: [UUID: OverlayWindowController] = [:]
    private let configURL: URL
    private var persistedOpen: [OpenWindowState]
    private var saveWork: DispatchWorkItem?
    private var screenChangeWork: DispatchWorkItem?

    weak var secureHost: SecureModeHost?

    // Secure lock-screen state
    private var lockWindow: OverlayWindow?
    private var lockVC: OverlayWebViewController?
    private var blackoutWindows: [OverlayWindow] = []
    private(set) var isSecureLockActive = false

    init(configURL: URL) {
        self.configURL = configURL
        let cfg = AppConfig.load(from: configURL)
        self.pages = cfg.pages
        self.globals = cfg.globals
        self.persistedOpen = cfg.openWindows
    }

    // MARK: - Lifecycle

    func start() {
        if globals.isLockScreenMode {
            enterSecureLock()
        } else {
            restoreWindows()
        }
    }

    private func restoreWindows() {
        for state in persistedOpen {
            guard let page = pages.first(where: { $0.id == state.pageID }) else { continue }
            openWindow(page: page, state: state, persist: false)
        }
        persist()
    }

    // MARK: - Window open/close

    func isOpen(_ id: UUID) -> Bool { controllers[id] != nil }
    var openPageIDs: Set<UUID> { Set(controllers.keys) }

    func openOrToggle(pageID: UUID) {
        if controllers[pageID] != nil {
            closeWindow(pageID: pageID)
        } else {
            openWindow(pageID: pageID)
        }
    }

    func openWindow(pageID: UUID) {
        guard controllers[pageID] == nil,
              let page = pages.first(where: { $0.id == pageID }) else { return }
        openWindow(page: page, state: OpenWindowState(pageID: pageID), persist: true)
    }

    private func openWindow(page: Page, state: OpenWindowState, persist doPersist: Bool) {
        let screen = resolveScreen(state.preferredDisplay)
        let frame = state.frame ?? screen.frame
        let ctrl = OverlayWindowController(
            page: page,
            autoReloadInterval: globals.autoReloadInterval,
            preferredDisplay: state.preferredDisplay ?? screen.makeDisplayRef(),
            isMovable: state.isMovable ?? false,
            clickThrough: globals.isClickThrough,
            frame: frame)
        controllers[page.id] = ctrl
        ctrl.show()
        objectWillChange.send()
        if doPersist { persist() }
    }

    func closeWindow(pageID: UUID) {
        guard let ctrl = controllers[pageID] else { return }
        ctrl.close()
        controllers[pageID] = nil
        objectWillChange.send()
        persist()
    }

    func reload(pageID: UUID) { controllers[pageID]?.reload() }

    // MARK: - Per-window controls

    func isMovable(_ id: UUID) -> Bool { controllers[id]?.isMovable ?? false }

    func setMovable(pageID: UUID, _ on: Bool) {
        controllers[pageID]?.setMovable(on)
        objectWillChange.send()
        persist()
    }

    func opacity(_ id: UUID) -> CGFloat {
        controllers[id]?.page.opacity ?? pages.first(where: { $0.id == id })?.opacity ?? 0.3
    }

    func setOpacity(pageID: UUID, _ a: CGFloat) {
        controllers[pageID]?.setOpacity(a)
        if let i = pages.firstIndex(where: { $0.id == pageID }) { pages[i].opacity = a }
        persist()
    }

    // MARK: - Displays

    func currentDisplay(_ id: UUID) -> DisplayRef? {
        guard let ctrl = controllers[id] else { return nil }
        return ctrl.window.screen?.makeDisplayRef() ?? ctrl.preferredDisplay
    }

    func reassignDisplay(pageID: UUID, to ref: DisplayRef) {
        guard let ctrl = controllers[pageID], let screen = NSScreen.screen(matching: ref) else { return }
        ctrl.preferredDisplay = ref
        ctrl.place(on: screen)
        objectWillChange.send()
        persist()
    }

    private func resolveScreen(_ ref: DisplayRef?) -> NSScreen {
        if let ref, let s = NSScreen.screen(matching: ref) { return s }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    func handleScreenChange() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyScreenChange() }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func applyScreenChange() {
        for ctrl in controllers.values {
            let screen = resolveScreen(ctrl.preferredDisplay)
            ctrl.place(on: screen)
        }
        if isSecureLockActive, globals.isSecureMode { refreshBlackouts() }
        objectWillChange.send()
        persist()
    }

    // MARK: - Global click-through

    func toggleGlobalClickThrough() { setGlobalClickThrough(!globals.isClickThrough) }

    func setGlobalClickThrough(_ on: Bool) {
        globals.isClickThrough = on
        for c in controllers.values { c.applyClickThrough(on) }
        persist()
    }

    // MARK: - Page CRUD

    @discardableResult
    func addPage(name: String, url: URL?) -> Page {
        let page = Page(name: name, url: url)
        pages.append(page)
        persist()
        return page
    }

    func deletePage(id: UUID) {
        if controllers[id] != nil { closeWindow(pageID: id) }
        pages.removeAll { $0.id == id }
        persist()
    }

    /// Re-apply edited page data to an open window (opacity + reload on URL/color change).
    func applyPageEdits(_ page: Page) {
        guard let ctrl = controllers[page.id] else { persist(); return }
        let changedContent = ctrl.page.url != page.url || ctrl.page.color != page.color
        ctrl.setOpacity(page.opacity)
        if changedContent {
            let state = ctrl.currentState()
            ctrl.close()
            controllers[page.id] = nil
            openWindow(page: page, state: state, persist: false)
        }
        persist()
    }

    /// Apply edited global settings to all open windows; enter lock mode if newly enabled.
    func applyGlobalSettings() {
        if globals.isLockScreenMode && !isSecureLockActive {
            persist()
            enterSecureLock()
            return
        }
        for c in controllers.values { c.applyClickThrough(globals.isClickThrough) }
        rebuildOpenWindows()   // pick up new auto-reload interval
        persist()
    }

    private func rebuildOpenWindows() {
        let states = controllers.values.map { $0.currentState() }
        for c in controllers.values { c.close() }
        controllers.removeAll()
        for state in states {
            guard let page = pages.first(where: { $0.id == state.pageID }) else { continue }
            openWindow(page: page, state: state, persist: false)
        }
        objectWillChange.send()
    }

    // MARK: - Pause / resume

    func pauseAll() {
        controllers.values.forEach { $0.pause() }
        lockVC?.pauseWebContent()
    }

    func resumeAll() {
        controllers.values.forEach { $0.resume() }
        lockVC?.resumeWebContent()
    }

    // MARK: - Secure lock screen

    func enterSecureLock() {
        guard !isSecureLockActive else { return }
        isSecureLockActive = true

        controllers.values.forEach { $0.hide() }

        let mainScreen = NSScreen.main ?? NSScreen.screens.first!
        let w = OverlayWindow(contentRect: mainScreen.frame, role: .lock)
        let vc = OverlayWebViewController(content: .lockScreen(globals))
        vc.onUnlockSuccess = { [weak self] in self?.exitSecureLock() }
        w.contentViewController = vc
        w.alphaValue = 1.0
        w.ignoresMouseEvents = false
        w.setInteractive(true)
        w.bringToFront()
        lockWindow = w
        lockVC = vc
        NSApp.activate(ignoringOtherApps: true)

        if globals.isSecureMode {
            refreshBlackouts()
            secureHost?.engageSecureKiosk()
        }
    }

    private func refreshBlackouts() {
        let mainScreen = lockWindow?.screen ?? NSScreen.main
        blackoutWindows.forEach { $0.orderOut(nil) }
        blackoutWindows.removeAll()

        for screen in NSScreen.screens where screen != mainScreen {
            let bw = OverlayWindow(contentRect: screen.frame, role: .blackout)
            let cover = NSViewController()
            cover.view = NSView(frame: screen.frame)
            cover.view.wantsLayer = true
            cover.view.layer?.backgroundColor = NSColor.black.cgColor

            let label = NSTextField(labelWithString: "🔒")
            label.font = NSFont.systemFont(ofSize: 72)
            label.textColor = .white
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            cover.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cover.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: cover.view.centerYAnchor)
            ])

            bw.contentViewController = cover
            bw.alphaValue = 1.0
            bw.ignoresMouseEvents = false
            bw.orderFront(nil)
            blackoutWindows.append(bw)
        }
    }

    /// Called on successful unlock. Tears down secure mode and terminates the app.
    func exitSecureLock() {
        secureHost?.disengageSecureKiosk()
        blackoutWindows.forEach { $0.orderOut(nil) }
        blackoutWindows.removeAll()
        lockWindow?.orderOut(nil)
        lockWindow = nil
        lockVC = nil
        isSecureLockActive = false
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Persistence

    func save() { persist() }

    func persist() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeConfig() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeConfig() {
        let openStates = controllers.values.map { $0.currentState() }
        let cfg = AppConfig(pages: pages, globals: globals, openWindows: openStates)
        cfg.save(to: configURL)
    }
}
