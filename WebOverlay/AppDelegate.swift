import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var globalHotKeyRef: EventHotKeyRef?
    private var quitHotKeyRef: EventHotKeyRef?
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
        setupWindow()
        setupGlobalHotKey()
        setupSleepWakeNotifications()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
        removeSleepWakeNotifications()
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
    let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    NSLog("[Overlay] Creating overlay window at frame: \(NSStringFromRect(screenFrame))")
        window = OverlayWindow(contentRect: screenFrame)

        let vc = OverlayWebViewController(config: config)
        window.contentViewController = vc
        window.alphaValue = config.opacity
        window.ignoresMouseEvents = config.isClickThrough

    window.makeKeyAndOrderFront(nil)
    NSLog("[Overlay] Window visible (alpha=\(window.alphaValue), clickThrough=\(window.ignoresMouseEvents))")
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
}
