import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var additionalWindows: [OverlayWindow] = []
    private var globalHotKeyRef: EventHotKeyRef?
    private var quitHotKeyRef: EventHotKeyRef?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var config: OverlayConfig = {
        // Attempt to load from ~/Library/Application Support/WebOverlay/config.json
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("WebOverlay", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent("config.json")
        return OverlayConfig.load(from: cfgURL)
    }()

    private var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("WebOverlay", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Overlay] applicationDidFinishLaunching")

        // Hash password if needed (converts plaintext to sha256: prefixed hash)
        if config.isLockScreenMode {
            config.hashPasswordIfNeeded()
            config.save(to: configURL)
        }

        setupWindow()

        // In secure lock screen mode, don't register hotkeys that could bypass the lock
        if !config.isSecureMode {
            setupGlobalHotKey()
        } else {
            NSLog("[Overlay] Secure mode enabled - hotkeys disabled")

            // Check accessibility permissions and setup secure mode
            if checkAccessibilityPermissions() {
                setupSecureModeWithEventTap()
                setupPresentationOptions()
            } else {
                // Fall back to best-effort monitoring without event tap
                NSLog("[Overlay] Accessibility not granted - using fallback security")
                setupSecureModeEventMonitoring()
            }
        }

        setupSleepWakeNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        removeSleepWakeNotifications()
        removeSecureModeEventMonitoring()
        removeEventTap()
        restorePresentationOptions()
    }

    // MARK: - Accessibility Permission Check

    private func checkAccessibilityPermissions() -> Bool {
        // Only check/prompt in secure mode
        guard config.isSecureMode else { return false }

        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("[Overlay] Accessibility permission not granted")

            // Show alert to user
            DispatchQueue.main.async { [weak self] in
                self?.showAccessibilityPermissionAlert()
            }

            return false
        }

        NSLog("[Overlay] Accessibility permission granted")
        return true
    }

    private func showAccessibilityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Secure lock screen mode requires Accessibility permissions to block system shortcuts like Cmd+Tab and Cmd+Space.\n\nWithout this permission, the lock screen provides reduced security."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue Anyway")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open System Settings to Accessibility pane
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CGEventTap for System-Wide Key Blocking

    private func setupSecureModeWithEventTap() {
        NSLog("[Overlay] Setting up CGEventTap for secure mode")

        // Events to intercept: keyDown, keyUp, and flagsChanged
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)

        // Create event tap at session level to intercept before any app
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                // Handle tap disabled event
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    NSLog("[Overlay] Event tap was disabled, re-enabling")
                    if let refcon = refcon {
                        let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = delegate.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }

                guard let refcon = refcon else {
                    return Unmanaged.passRetained(event)
                }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleEventTapEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[Overlay] Failed to create event tap - falling back to NSEvent monitoring")
            setupSecureModeEventMonitoring()
            return
        }

        eventTap = tap

        // Create run loop source and add to current run loop
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the tap
        CGEvent.tapEnable(tap: tap, enable: true)

        NSLog("[Overlay] CGEventTap enabled successfully")
    }

    private func handleEventTapEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Check for blocked key combinations
        let hasCommand = flags.contains(.maskCommand)
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)

        // Block Cmd+Tab (app switching) - keyCode 48
        if hasCommand && keyCode == 48 {
            NSLog("[Overlay] Blocked Cmd+Tab via event tap")
            return nil
        }

        // Block Cmd+Space (Spotlight) - keyCode 49
        if hasCommand && keyCode == 49 {
            NSLog("[Overlay] Blocked Cmd+Space via event tap")
            return nil
        }

        // Block Cmd+Opt+Esc (Force Quit) - keyCode 53
        if hasCommand && hasOption && keyCode == 53 {
            NSLog("[Overlay] Blocked Cmd+Opt+Esc via event tap")
            return nil
        }

        // Block Cmd+Q (quit)
        if hasCommand && keyCode == 12 {
            NSLog("[Overlay] Blocked Cmd+Q via event tap")
            return nil
        }

        // Block Cmd+W (close window)
        if hasCommand && keyCode == 13 {
            NSLog("[Overlay] Blocked Cmd+W via event tap")
            return nil
        }

        // Block Cmd+H (hide)
        if hasCommand && keyCode == 4 {
            NSLog("[Overlay] Blocked Cmd+H via event tap")
            return nil
        }

        // Block Cmd+M (minimize)
        if hasCommand && keyCode == 46 {
            NSLog("[Overlay] Blocked Cmd+M via event tap")
            return nil
        }

        // Block Control+Arrow keys (Spaces switching)
        if hasControl {
            // Left arrow = 123, Right arrow = 124, Up arrow = 126, Down arrow = 125
            if keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126 {
                NSLog("[Overlay] Blocked Ctrl+Arrow via event tap")
                return nil
            }
        }

        // Block F3 (Mission Control) - keyCode 99
        if keyCode == 99 {
            NSLog("[Overlay] Blocked F3 (Mission Control) via event tap")
            return nil
        }

        // Block Ctrl+Up (Mission Control alternative)
        if hasControl && keyCode == 126 {
            NSLog("[Overlay] Blocked Ctrl+Up via event tap")
            return nil
        }

        // Block F11 (Show Desktop) - keyCode 103
        if keyCode == 103 {
            NSLog("[Overlay] Blocked F11 via event tap")
            return nil
        }

        // Allow Escape key through to the WebView for lock screen prompt dismissal

        // Block Cmd+` (window switching within app)
        if hasCommand && keyCode == 50 {
            NSLog("[Overlay] Blocked Cmd+` via event tap")
            return nil
        }

        // Allow the event (for password entry and other legitimate use)
        return Unmanaged.passRetained(event)
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }

        NSLog("[Overlay] Event tap removed")
    }

    // MARK: - Presentation Options (Kiosk Mode)

    private func setupPresentationOptions() {
        guard config.isSecureMode else { return }

        NSLog("[Overlay] Enabling presentation options for secure mode")

        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication
        ]
    }

    private func restorePresentationOptions() {
        NSApp.presentationOptions = []
        NSLog("[Overlay] Presentation options restored")
    }

    /// Call this when the lock screen is successfully unlocked
    func unlockSecureMode() {
        removeEventTap()
        restorePresentationOptions()
        removeSecureModeEventMonitoring()

        // Close additional monitor windows
        for window in additionalWindows {
            window.orderOut(nil)
        }
        additionalWindows.removeAll()

        NSLog("[Overlay] Secure mode unlocked")
    }

    // MARK: - Sleep / Wake / Screen Lock handling
    private var workspaceSleepObserver: Any?
    private var workspaceWakeObserver: Any?
    private var screenLockedObserver: NSObjectProtocol?
    private var screenUnlockedObserver: NSObjectProtocol?

    private func setupSleepWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceSleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] willSleepNotification received")
            self?.pauseOverlayContent()
        }

        workspaceWakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] didWakeNotification received")
            self?.resumeOverlayContent()
        }

        // Screen lock/unlock notifications are posted on the distributed notification center
        let dnc = DistributedNotificationCenter.default()
        screenLockedObserver = dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] screen locked")
            self?.pauseOverlayContent()
        }
        screenUnlockedObserver = dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] screen unlocked")
            self?.resumeOverlayContent()
        }
    }

    private func removeSleepWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        if let obs = workspaceSleepObserver { nc.removeObserver(obs); workspaceSleepObserver = nil }
        if let obs = workspaceWakeObserver { nc.removeObserver(obs); workspaceWakeObserver = nil }

        let dnc = DistributedNotificationCenter.default()
        if let obs = screenLockedObserver { dnc.removeObserver(obs); screenLockedObserver = nil }
        if let obs = screenUnlockedObserver { dnc.removeObserver(obs); screenUnlockedObserver = nil }
    }

    private func pauseOverlayContent() {
        if let vc = window.contentViewController as? OverlayWebViewController {
            vc.pauseWebContent()
        }
    }

    private func resumeOverlayContent() {
        if let vc = window.contentViewController as? OverlayWebViewController {
            vc.resumeWebContent()
        }
    }

    private func setupWindow() {
        let screens = NSScreen.screens
        let mainScreen = NSScreen.main ?? screens.first!

        NSLog("[Overlay] Creating overlay window for main screen: \(NSStringFromRect(mainScreen.frame))")
        window = OverlayWindow(contentRect: mainScreen.frame, isSecureMode: config.isSecureMode)

        let vc = OverlayWebViewController(config: config)
        window.contentViewController = vc

        // In lock screen mode, force full opacity and interactivity
        if config.isLockScreenMode {
            window.alphaValue = 1.0
            window.ignoresMouseEvents = false
            window.updateInteractiveMode(true)
            NSLog("[Overlay] Lock screen mode - forcing full opacity and interactivity")

            // Create windows for additional displays in secure mode
            if config.isSecureMode && screens.count > 1 {
                setupMultiMonitorWindows(excluding: mainScreen)
            }
        } else {
            window.alphaValue = config.opacity
            window.ignoresMouseEvents = config.isClickThrough
        }

        window.makeKeyAndOrderFront(nil)
        NSLog("[Overlay] Window visible (alpha=\(window.alphaValue), clickThrough=\(window.ignoresMouseEvents))")
    }

    private func setupMultiMonitorWindows(excluding mainScreen: NSScreen) {
        for screen in NSScreen.screens where screen != mainScreen {
            NSLog("[Overlay] Creating overlay window for additional screen: \(NSStringFromRect(screen.frame))")

            let additionalWindow = OverlayWindow(contentRect: screen.frame, isSecureMode: true)

            // Create a simple black cover for additional displays
            let coverVC = NSViewController()
            coverVC.view = NSView(frame: screen.frame)
            coverVC.view.wantsLayer = true
            coverVC.view.layer?.backgroundColor = NSColor.black.cgColor

            // Add a "locked" label
            let label = NSTextField(labelWithString: "🔒")
            label.font = NSFont.systemFont(ofSize: 72)
            label.textColor = .white
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            coverVC.view.addSubview(label)

            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: coverVC.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: coverVC.view.centerYAnchor)
            ])

            additionalWindow.contentViewController = coverVC
            additionalWindow.alphaValue = 1.0
            additionalWindow.ignoresMouseEvents = false
            additionalWindow.makeKeyAndOrderFront(nil)

            additionalWindows.append(additionalWindow)
        }

        NSLog("[Overlay] Created \(additionalWindows.count) additional monitor windows")
    }

    private func setupGlobalHotKey() {
        // Register global hotkey: Command+Option+Shift+O (toggle click-through)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F564C59), id: 1) // 'OVLY'
        var eventHotKey: EventHotKeyRef?

        // KeyCode for 'O' is 31
        let keyCode: UInt32 = 31
        let modifiers: UInt32 = UInt32(cmdKey | optionKey | shiftKey)

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &eventHotKey
        )

        if status == noErr {
            globalHotKeyRef = eventHotKey
            NSLog("[Overlay] Global hotkey registered: Cmd+Opt+Shift+O")
        } else {
            NSLog("[Overlay] Failed to register global hotkey: \(status)")
        }

        // Register global hotkey: Command+Option+Shift+K (quit app)
        let quitHotKeyID = EventHotKeyID(signature: OSType(0x4F564C59), id: 2) // 'OVLY' with id 2
        var quitEventHotKey: EventHotKeyRef?

        // KeyCode for 'K' is 40
        let quitKeyCode: UInt32 = 40

        let quitStatus = RegisterEventHotKey(
            quitKeyCode,
            modifiers,
            quitHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &quitEventHotKey
        )

        if quitStatus == noErr {
            quitHotKeyRef = quitEventHotKey
            NSLog("[Overlay] Global hotkey registered: Cmd+Opt+Shift+K (quit)")
        } else {
            NSLog("[Overlay] Failed to register quit hotkey: \(quitStatus)")
        }

        // Install Carbon event handler for all hotkeys
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if status == noErr {
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        delegate.toggleClickThrough()
                    case 2:
                        NSLog("[Overlay] Quit hotkey pressed, terminating app")
                        NSApplication.shared.terminate(nil)
                    default:
                        break
                    }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef = globalHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            globalHotKeyRef = nil
            NSLog("[Overlay] Global hotkey unregistered")
        }
        if let hotKeyRef = quitHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            quitHotKeyRef = nil
            NSLog("[Overlay] Quit hotkey unregistered")
        }
    }

    private func toggleClickThrough() {
        window.ignoresMouseEvents.toggle()
        config.isClickThrough = window.ignoresMouseEvents
        config.save(to: configURL)

        // Update window's ability to receive keyboard input
        window.updateInteractiveMode(!window.ignoresMouseEvents)

        showEphemeralHUD(text: window.ignoresMouseEvents ? "Click-Through" : "Interactive")
    }

    private var hudWindow: NSWindow?
    private var hudCloseWorkItem: DispatchWorkItem?

    private func showEphemeralHUD(text: String) {
        // Cancel any pending close operation
        hudCloseWorkItem?.cancel()
        hudCloseWorkItem = nil

        // Close existing HUD window safely
        if let existingHUD = hudWindow {
            existingHUD.orderOut(nil)
            hudWindow = nil
        }

        let size = NSSize(width: 220, height: 60)
        let frame = NSRect(x: (window.frame.width - size.width)/2, y: (window.frame.height - size.height)/2, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar + 1  // Above the overlay window
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        w.hasShadow = true
        w.ignoresMouseEvents = true

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (size.width - label.frame.width)/2, y: (size.height - label.frame.height)/2)
        w.contentView?.addSubview(label)
        w.makeKeyAndOrderFront(nil)
        hudWindow = w

        // Schedule close with cancellable work item
        let workItem = DispatchWorkItem { [weak self, weak w] in
            w?.orderOut(nil)
            if self?.hudWindow === w {
                self?.hudWindow = nil
            }
        }
        hudCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: - Secure Mode Event Monitoring (Fallback)

    private func setupSecureModeEventMonitoring() {
        // Monitor local events (within the app) to prevent certain key combinations
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            return self?.handleSecureModeKeyEvent(event)
        }

        // Monitor global events (system-wide) to try to capture events before other apps
        // Note: This requires accessibility permissions to fully work
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Global monitor can only observe, not block, but we keep the window focused
            self?.window.makeKeyAndOrderFront(nil)
        }

        NSLog("[Overlay] Secure mode event monitoring enabled (fallback mode)")
    }

    private func handleSecureModeKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Block Command+Q to prevent quitting via keyboard
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            NSLog("[Overlay] Blocked Cmd+Q in secure mode")
            return nil
        }

        // Block Command+W to prevent window close
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            NSLog("[Overlay] Blocked Cmd+W in secure mode")
            return nil
        }

        // Block Command+Tab to prevent app switching (best effort)
        if event.modifierFlags.contains(.command) && event.keyCode == 48 {
            NSLog("[Overlay] Blocked Cmd+Tab in secure mode")
            return nil
        }

        // Allow Escape key through for lock screen prompt dismissal

        // Allow the event for password entry
        return event
    }

    private func removeSecureModeEventMonitoring() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        NSLog("[Overlay] Secure mode event monitoring removed")
    }
}
