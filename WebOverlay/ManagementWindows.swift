import SwiftUI
import AppKit

/// Presents on-demand management windows for a menu-bar (.accessory) app,
/// flipping activation policy so SwiftUI text fields can receive keyboard focus.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()
    private var manageWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showManagePages(manager: OverlayManager) {
        if manageWindow == nil {
            let host = NSHostingController(rootView: ManagePagesView(manager: manager))
            manageWindow = makeWindow(host, title: "Manage Pages", size: NSSize(width: 520, height: 420))
        }
        present(manageWindow!)
    }

    func showSettings(manager: OverlayManager) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(manager: manager))
            settingsWindow = makeWindow(host, title: "Settings", size: NSSize(width: 480, height: 460))
        }
        present(settingsWindow!)
    }

    func closeManagePages() { manageWindow?.close() }
    func closeSettings() { settingsWindow?.close() }

    private func makeWindow(_ vc: NSViewController, title: String, size: NSSize) -> NSWindow {
        let w = NSWindow(contentViewController: vc)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(size)
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // After the window finishes closing, drop back to agent mode if nothing else is open.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = [self.manageWindow, self.settingsWindow].contains { $0?.isVisible == true }
            if !anyVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - Manage Pages

struct ManagePagesView: View {
    @ObservedObject var manager: OverlayManager
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($manager.pages) { $page in
                    HStack(spacing: 8) {
                        TextField("Name", text: $page.name)
                            .onSubmit { manager.applyPageEdits(page) }
                        TextField("https://…", text: Binding(
                            get: { page.url?.absoluteString ?? "" },
                            set: { page.url = URL(string: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { manager.applyPageEdits(page) }
                    }
                    .tag(page.id)
                }
                .onMove { manager.pages.move(fromOffsets: $0, toOffset: $1); manager.save() }
                .onDelete { offsets in
                    offsets.map { manager.pages[$0].id }.forEach { manager.deletePage(id: $0) }
                }
            }

            Divider()

            HStack {
                Button {
                    let p = manager.addPage(name: "New Page", url: URL(string: "https://example.com"))
                    selection = p.id
                } label: { Image(systemName: "plus") }

                Button {
                    if let s = selection { manager.deletePage(id: s); selection = nil }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)

                Spacer()
                Button("Done") { WindowPresenter.shared.closeManagePages() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onDisappear { manager.save() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var manager: OverlayManager
    @State private var plaintextPassword = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Overlay Defaults") {
                    Toggle("Click-through by default", isOn: $manager.globals.isClickThrough)

                    Toggle("Auto-reload pages", isOn: autoReloadEnabled)
                    if manager.globals.autoReloadInterval != nil {
                        HStack {
                            Text("Interval (seconds)")
                            Spacer()
                            TextField("", value: autoReloadValue, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    TextField("Fallback color (#RRGGBB)", text: colorBinding)

                    Toggle("Unload pages while hidden (sleep/lock)", isOn: $manager.globals.unloadWhenHidden)
                }

                Section("Fake Lock Screen") {
                    Toggle("Enable fake lock screen", isOn: lockEnabled)
                    if lockEnabled.wrappedValue {
                        SecureField("Password (blank = keep current)", text: $plaintextPassword)
                        TextField("Message", text: lockMessage)
                        Toggle("Secure mode (block system shortcuts)", isOn: lockSecure)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { applyAndSave(); WindowPresenter.shared.closeSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
        .frame(width: 480, height: 460)
        .onDisappear { applyAndSave() }
    }

    // MARK: Bindings

    private var autoReloadEnabled: Binding<Bool> {
        Binding(get: { manager.globals.autoReloadInterval != nil },
                set: { manager.globals.autoReloadInterval = $0 ? 300 : nil })
    }
    private var autoReloadValue: Binding<Double> {
        Binding(get: { manager.globals.autoReloadInterval ?? 300 },
                set: { manager.globals.autoReloadInterval = $0 })
    }
    private var colorBinding: Binding<String> {
        Binding(get: { manager.globals.color ?? "" },
                set: { manager.globals.color = $0.isEmpty ? nil : $0 })
    }
    private var lockEnabled: Binding<Bool> {
        Binding(get: { manager.globals.fakeLockScreen?.enable ?? false },
                set: { on in
                    var l = manager.globals.fakeLockScreen ?? .default
                    l.enable = on
                    manager.globals.fakeLockScreen = l
                })
    }
    private var lockMessage: Binding<String> {
        Binding(get: { manager.globals.fakeLockScreen?.message ?? "" },
                set: { v in
                    var l = manager.globals.fakeLockScreen ?? .default
                    l.message = v.isEmpty ? nil : v
                    manager.globals.fakeLockScreen = l
                })
    }
    private var lockSecure: Binding<Bool> {
        Binding(get: { manager.globals.fakeLockScreen?.secure ?? false },
                set: { v in
                    var l = manager.globals.fakeLockScreen ?? .default
                    l.secure = v
                    manager.globals.fakeLockScreen = l
                })
    }

    private func applyAndSave() {
        if !plaintextPassword.isEmpty {
            var l = manager.globals.fakeLockScreen ?? .default
            l.password = plaintextPassword
            manager.globals.fakeLockScreen = l.withHashedPassword()
            plaintextPassword = ""
        }
        manager.applyGlobalSettings()
    }
}
