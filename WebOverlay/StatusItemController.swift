import AppKit
import Combine

/// A menu row hosting an opacity slider for one open window.
final class OpacitySliderItemView: NSView {
    private let slider = NSSlider()
    private let pageID: UUID
    private let onChange: (UUID, CGFloat) -> Void

    init(pageID: UUID, value: CGFloat, onChange: @escaping (UUID, CGFloat) -> Void) {
        self.pageID = pageID
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 30))

        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        slider.minValue = 0.05
        slider.maxValue = 1.0
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() {
        onChange(pageID, CGFloat(slider.doubleValue))
    }
}

/// Owns the menu-bar status item and builds its menu on demand from the OverlayManager.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let manager: OverlayManager
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellable: AnyCancellable?

    init(manager: OverlayManager) {
        self.manager = manager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WebOverlay")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu

        cancellable = manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
        refreshButton()
    }

    private func refreshButton() {
        let symbol = manager.openPageIDs.isEmpty ? "rectangle.on.rectangle" : "rectangle.on.rectangle.fill"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WebOverlay")
        statusItem.button?.image?.isTemplate = true
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Pages", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if manager.pages.isEmpty {
            let empty = NSMenuItem(title: "No pages yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for page in manager.pages {
            let item = NSMenuItem(title: page.displayName, action: #selector(togglePage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = page.id
            if manager.isOpen(page.id) {
                item.state = .on
                item.submenu = makeWindowSubmenu(page: page)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let secureLockBusy = manager.isSecureLockActive

        let interaction = NSMenuItem(title: manager.globals.isClickThrough ? "Enable Interaction (all windows)" : "Disable Interaction (all windows)",
                                     action: #selector(toggleInteraction), keyEquivalent: "")
        interaction.target = self
        interaction.isEnabled = !secureLockBusy
        menu.addItem(interaction)

        menu.addItem(.separator())

        let managePages = NSMenuItem(title: "Manage Pages…", action: #selector(openManagePages), keyEquivalent: "")
        managePages.target = self
        managePages.isEnabled = !secureLockBusy
        menu.addItem(managePages)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settings.isEnabled = !secureLockBusy
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WebOverlay", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeWindowSubmenu(page: Page) -> NSMenu {
        let submenu = NSMenu()

        let sliderItem = NSMenuItem()
        sliderItem.view = OpacitySliderItemView(pageID: page.id, value: manager.opacity(page.id)) { [weak self] id, v in
            self?.manager.setOpacity(pageID: id, v)
        }
        submenu.addItem(sliderItem)

        submenu.addItem(.separator())

        let movable = NSMenuItem(title: "Movable (drag to move)", action: #selector(toggleMovable(_:)), keyEquivalent: "")
        movable.target = self
        movable.representedObject = page.id
        movable.state = manager.isMovable(page.id) ? .on : .off
        submenu.addItem(movable)

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let current = manager.currentDisplay(page.id)
        for screen in NSScreen.screens {
            guard let ref = screen.makeDisplayRef() else { continue }
            let title = ref.localizedName ?? "Display"
            let di = NSMenuItem(title: title, action: #selector(reassignDisplay(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = DisplayAssignment(pageID: page.id, display: ref)
            di.state = (ref.uuid == current?.uuid) ? .on : .off
            displayMenu.addItem(di)
        }
        displayItem.submenu = displayMenu
        submenu.addItem(displayItem)

        submenu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload", action: #selector(reloadWindow(_:)), keyEquivalent: "")
        reload.target = self
        reload.representedObject = page.id
        submenu.addItem(reload)

        let close = NSMenuItem(title: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = page.id
        submenu.addItem(close)

        return submenu
    }

    /// Box for passing a (pageID, display) pair as representedObject.
    private final class DisplayAssignment: NSObject {
        let pageID: UUID
        let display: DisplayRef
        init(pageID: UUID, display: DisplayRef) { self.pageID = pageID; self.display = display }
    }

    // MARK: - Actions

    @objc private func togglePage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.openOrToggle(pageID: id)
    }

    @objc private func toggleMovable(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.setMovable(pageID: id, !manager.isMovable(id))
    }

    @objc private func reassignDisplay(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? DisplayAssignment else { return }
        manager.reassignDisplay(pageID: a.pageID, to: a.display)
    }

    @objc private func reloadWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.reload(pageID: id)
    }

    @objc private func closeWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        manager.closeWindow(pageID: id)
    }

    @objc private func toggleInteraction() {
        manager.toggleGlobalClickThrough()
    }

    @objc private func openManagePages() {
        WindowPresenter.shared.showManagePages(manager: manager)
    }

    @objc private func openSettings() {
        WindowPresenter.shared.showSettings(manager: manager)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
