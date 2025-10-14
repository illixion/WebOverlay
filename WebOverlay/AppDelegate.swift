import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow!
    private var globalHotKeyRef: EventHotKeyRef?
    private var config: OverlayConfig = {
        // Attempt to load from ~/Library/Application Support/Overlay/config.json
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("SwiftOverlay", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent("config.json")
        return OverlayConfig.load(from: cfgURL)
    }()

    private var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("SwiftOverlay", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Overlay] applicationDidFinishLaunching")
        setupWindow()
        setupGlobalHotKey()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
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
        // Register global hotkey: Command+Option+Shift+O
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
            
            // Install Carbon event handler
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
                
                if status == noErr && hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        delegate.toggleClickThrough()
                    }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), nil)
        } else {
            NSLog("[Overlay] Failed to register global hotkey: \(status)")
        }
    }
    
    private func unregisterGlobalHotKey() {
        if let hotKeyRef = globalHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            globalHotKeyRef = nil
            NSLog("[Overlay] Global hotkey unregistered")
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
