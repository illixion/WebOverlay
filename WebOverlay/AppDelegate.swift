import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, SecureModeHost {
    private var manager: OverlayManager!
    private var statusController: StatusItemController?

    private var globalHotKeyRef: EventHotKeyRef?
    private var quitHotKeyRef: EventHotKeyRef?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var configURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WebOverlay", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Overlay] applicationDidFinishLaunching")

        let manager = OverlayManager(configURL: configURL)
        manager.secureHost = self
        self.manager = manager
        statusController = StatusItemController(manager: manager)

        manager.start()

        // In secure lock screen mode, don't register hotkeys that could bypass the lock.
        if !manager.globals.isSecureMode {
            setupGlobalHotKey()
        } else {
            NSLog("[Overlay] Secure mode enabled - hotkeys disabled")
        }

        setupSleepWakeNotifications()
        setupScreenChangeNotification()
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        removeSleepWakeNotifications()
        removeScreenChangeNotification()
        removeSecureModeEventMonitoring()
        removeEventTap()
        restorePresentationOptions()
    }

    // MARK: - SecureModeHost

    func engageSecureKiosk() {
        if checkAccessibilityPermissions() {
            setupSecureModeWithEventTap()
            setupPresentationOptions()
        } else {
            NSLog("[Overlay] Accessibility not granted - using fallback security")
            setupSecureModeEventMonitoring()
        }
    }

    func disengageSecureKiosk() {
        removeEventTap()
        restorePresentationOptions()
        removeSecureModeEventMonitoring()
        NSLog("[Overlay] Secure kiosk disengaged")
    }

    // MARK: - Accessibility Permission Check

    private func checkAccessibilityPermissions() -> Bool {
        guard manager.globals.isSecureMode else { return false }

        let trusted = AXIsProcessTrusted()
        if !trusted {
            NSLog("[Overlay] Accessibility permission not granted")
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
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - CGEventTap for System-Wide Key Blocking

    private func setupSecureModeWithEventTap() {
        NSLog("[Overlay] Setting up CGEventTap for secure mode")

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
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
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[Overlay] CGEventTap enabled successfully")
    }

    private func handleEventTapEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let hasCommand = flags.contains(.maskCommand)
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)

        if hasCommand && keyCode == 48 { NSLog("[Overlay] Blocked Cmd+Tab"); return nil }
        if hasCommand && keyCode == 49 { NSLog("[Overlay] Blocked Cmd+Space"); return nil }
        if hasCommand && hasOption && keyCode == 53 { NSLog("[Overlay] Blocked Cmd+Opt+Esc"); return nil }
        if hasCommand && keyCode == 12 { NSLog("[Overlay] Blocked Cmd+Q"); return nil }
        if hasCommand && keyCode == 13 { NSLog("[Overlay] Blocked Cmd+W"); return nil }
        if hasCommand && keyCode == 4 { NSLog("[Overlay] Blocked Cmd+H"); return nil }
        if hasCommand && keyCode == 46 { NSLog("[Overlay] Blocked Cmd+M"); return nil }
        if hasControl && (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126) {
            NSLog("[Overlay] Blocked Ctrl+Arrow"); return nil
        }
        if keyCode == 99 { NSLog("[Overlay] Blocked F3"); return nil }
        if keyCode == 103 { NSLog("[Overlay] Blocked F11"); return nil }
        if hasCommand && keyCode == 50 { NSLog("[Overlay] Blocked Cmd+`"); return nil }

        // Allow Escape and password-entry keys through.
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
        guard manager.globals.isSecureMode else { return }
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

    // MARK: - Sleep / Wake / Screen Lock handling

    private var workspaceSleepObserver: Any?
    private var workspaceWakeObserver: Any?
    private var screenLockedObserver: NSObjectProtocol?
    private var screenUnlockedObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?

    private func setupSleepWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceSleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] willSleepNotification received")
            self?.manager.pauseAll()
        }
        workspaceWakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] didWakeNotification received")
            self?.manager.resumeAll()
        }

        let dnc = DistributedNotificationCenter.default()
        screenLockedObserver = dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] screen locked")
            self?.manager.pauseAll()
        }
        screenUnlockedObserver = dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            NSLog("[Overlay] screen unlocked")
            self?.manager.resumeAll()
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

    private func setupScreenChangeNotification() {
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            NSLog("[Overlay] screen parameters changed")
            self?.manager.handleScreenChange()
        }
    }

    private func removeScreenChangeNotification() {
        if let obs = screenParamsObserver { NotificationCenter.default.removeObserver(obs); screenParamsObserver = nil }
    }

    // MARK: - Global Hotkeys

    private func setupGlobalHotKey() {
        // Cmd+Option+Shift+O (toggle click-through for all windows)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F564C59), id: 1) // 'OVLY'
        var eventHotKey: EventHotKeyRef?
        let keyCode: UInt32 = 31 // 'O'
        let modifiers: UInt32 = UInt32(cmdKey | optionKey | shiftKey)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &eventHotKey)
        if status == noErr {
            globalHotKeyRef = eventHotKey
            NSLog("[Overlay] Global hotkey registered: Cmd+Opt+Shift+O")
        } else {
            NSLog("[Overlay] Failed to register global hotkey: \(status)")
        }

        // Cmd+Option+Shift+K (quit)
        let quitHotKeyID = EventHotKeyID(signature: OSType(0x4F564C59), id: 2)
        var quitEventHotKey: EventHotKeyRef?
        let quitKeyCode: UInt32 = 40 // 'K'
        let quitStatus = RegisterEventHotKey(quitKeyCode, modifiers, quitHotKeyID, GetEventDispatcherTarget(), 0, &quitEventHotKey)
        if quitStatus == noErr {
            quitHotKeyRef = quitEventHotKey
            NSLog("[Overlay] Global hotkey registered: Cmd+Opt+Shift+K (quit)")
        } else {
            NSLog("[Overlay] Failed to register quit hotkey: \(quitStatus)")
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { (_, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1: delegate.toggleClickThrough()
                    case 2:
                        NSLog("[Overlay] Quit hotkey pressed, terminating app")
                        NSApplication.shared.terminate(nil)
                    default: break
                    }
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func unregisterGlobalHotKey() {
        if let hotKeyRef = globalHotKeyRef { UnregisterEventHotKey(hotKeyRef); globalHotKeyRef = nil }
        if let hotKeyRef = quitHotKeyRef { UnregisterEventHotKey(hotKeyRef); quitHotKeyRef = nil }
    }

    private func toggleClickThrough() {
        manager.toggleGlobalClickThrough()
        showEphemeralHUD(text: manager.globals.isClickThrough ? "Click-Through" : "Interactive")
    }

    // MARK: - Ephemeral HUD

    private var hudWindow: NSWindow?
    private var hudCloseWorkItem: DispatchWorkItem?

    private func showEphemeralHUD(text: String) {
        hudCloseWorkItem?.cancel()
        hudCloseWorkItem = nil
        if let existingHUD = hudWindow {
            existingHUD.orderOut(nil)
            hudWindow = nil
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 220, height: 60)
        let frame = NSRect(x: screenFrame.midX - size.width / 2,
                           y: screenFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .statusBar + 1
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        w.hasShadow = true
        w.ignoresMouseEvents = true

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (size.width - label.frame.width) / 2, y: (size.height - label.frame.height) / 2)
        w.contentView?.addSubview(label)
        w.orderFront(nil)
        hudWindow = w

        let workItem = DispatchWorkItem { [weak self, weak w] in
            w?.orderOut(nil)
            if self?.hudWindow === w { self?.hudWindow = nil }
        }
        hudCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    // MARK: - Secure Mode Event Monitoring (Fallback)

    private func setupSecureModeEventMonitoring() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            return self?.handleSecureModeKeyEvent(event)
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { _ in
            NSApp.activate(ignoringOtherApps: true)
        }
        NSLog("[Overlay] Secure mode event monitoring enabled (fallback mode)")
    }

    private func handleSecureModeKeyEvent(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            NSLog("[Overlay] Blocked Cmd+Q in secure mode"); return nil
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            NSLog("[Overlay] Blocked Cmd+W in secure mode"); return nil
        }
        if event.modifierFlags.contains(.command) && event.keyCode == 48 {
            NSLog("[Overlay] Blocked Cmd+Tab in secure mode"); return nil
        }
        return event
    }

    private func removeSecureModeEventMonitoring() {
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor); localEventMonitor = nil }
        if let monitor = globalEventMonitor { NSEvent.removeMonitor(monitor); globalEventMonitor = nil }
        NSLog("[Overlay] Secure mode event monitoring removed")
    }
}
