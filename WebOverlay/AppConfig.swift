import Foundation
import AppKit

// MARK: - Page

/// A saved overlay page: a named URL (or solid color) with its own opacity.
struct Page: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var url: URL?
    var color: String?      // hex; if set + valid, renders a solid color instead of a URL
    var opacity: CGFloat    // per-page window opacity (0.05...1.0)

    init(id: UUID = UUID(), name: String, url: URL? = nil, color: String? = nil, opacity: CGFloat = 0.3) {
        self.id = id
        self.name = name
        self.url = url
        self.color = color
        self.opacity = opacity
    }

    enum CodingKeys: String, CodingKey { case id, name, url, color, opacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Overlay"
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        opacity = try c.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.3
    }

    /// The parsed NSColor from `color`, if valid.
    var parsedColor: NSColor? {
        guard let hex = color else { return nil }
        return NSColor(hexString: hex)
    }

    /// Whether this page renders a solid color instead of a web page.
    var isColorMode: Bool { parsedColor != nil }

    /// A short human label for menus.
    var displayName: String {
        if !name.isEmpty { return name }
        return url?.host ?? url?.absoluteString ?? "Overlay"
    }
}

// MARK: - DisplayRef

/// A stable reference to a physical display, persisted across reconnects.
struct DisplayRef: Codable, Hashable {
    var uuid: String            // CGDisplayCreateUUIDFromDisplayID string
    var localizedName: String?  // human label + fuzzy fallback
}

// MARK: - OpenWindowState

/// Persisted state for one open overlay window.
struct OpenWindowState: Codable {
    var pageID: UUID
    var preferredDisplay: DisplayRef?
    var frame: CGRect?
    var isMovable: Bool?

    init(pageID: UUID, preferredDisplay: DisplayRef? = nil, frame: CGRect? = nil, isMovable: Bool? = nil) {
        self.pageID = pageID
        self.preferredDisplay = preferredDisplay
        self.frame = frame
        self.isMovable = isMovable
    }
}

// MARK: - GlobalSettings

/// App-wide settings shared by all overlay windows.
struct GlobalSettings: Codable {
    var isClickThrough: Bool                 // applies to all windows; default on
    var autoReloadInterval: TimeInterval?
    var color: String?                       // legacy fallback color
    var fakeLockScreen: FakeLockScreenConfig?

    static let `default` = GlobalSettings(isClickThrough: true, autoReloadInterval: nil, color: nil, fakeLockScreen: nil)

    init(isClickThrough: Bool = true, autoReloadInterval: TimeInterval? = nil, color: String? = nil, fakeLockScreen: FakeLockScreenConfig? = nil) {
        self.isClickThrough = isClickThrough
        self.autoReloadInterval = autoReloadInterval
        self.color = color
        self.fakeLockScreen = fakeLockScreen
    }

    enum CodingKeys: String, CodingKey { case isClickThrough, autoReloadInterval, color, fakeLockScreen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isClickThrough = try c.decodeIfPresent(Bool.self, forKey: .isClickThrough) ?? true
        autoReloadInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .autoReloadInterval)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        fakeLockScreen = try c.decodeIfPresent(FakeLockScreenConfig.self, forKey: .fakeLockScreen)
    }

    /// Whether the fake lock screen mode is enabled.
    var isLockScreenMode: Bool { fakeLockScreen?.enable == true }

    /// Whether secure mode is enabled (captures input, disables hotkeys).
    var isSecureMode: Bool { isLockScreenMode && fakeLockScreen?.secure == true }

    /// Hash the lock-screen password in place if it's plaintext.
    mutating func hashPasswordIfNeeded() {
        guard let lock = fakeLockScreen, !lock.password.isEmpty, !lock.isPasswordHashed else { return }
        fakeLockScreen = lock.withHashedPassword()
    }

    /// Verify input against the stored lock-screen password.
    func verifyPassword(_ input: String) -> Bool {
        fakeLockScreen?.verifyPassword(input) ?? false
    }
}

// MARK: - AppConfig

/// The app's persisted data store.
struct AppConfig: Codable {
    var version: Int
    var pages: [Page]
    var globals: GlobalSettings
    var openWindows: [OpenWindowState]

    static let currentVersion = 2

    init(version: Int = AppConfig.currentVersion, pages: [Page], globals: GlobalSettings, openWindows: [OpenWindowState]) {
        self.version = version
        self.pages = pages
        self.globals = globals
        self.openWindows = openWindows
    }

    enum CodingKeys: String, CodingKey { case version, pages, globals, openWindows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? AppConfig.currentVersion
        pages = try c.decodeIfPresent([Page].self, forKey: .pages) ?? []
        globals = try c.decodeIfPresent(GlobalSettings.self, forKey: .globals) ?? .default
        openWindows = try c.decodeIfPresent([OpenWindowState].self, forKey: .openWindows) ?? []
    }

    static var `default`: AppConfig {
        let page = Page(name: "Apple", url: URL(string: "https://www.apple.com"), opacity: 0.3)
        return AppConfig(pages: [page], globals: .default,
                         openWindows: [OpenWindowState(pageID: page.id)])
    }

    /// Look up a page by id.
    func page(_ id: UUID) -> Page? { pages.first { $0.id == id } }
}

// MARK: - Migration & persistence

extension AppConfig {
    static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            let def = AppConfig.default
            def.save(to: url)
            return def
        }

        // New format: presence of "pages" key (or version >= 2)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["pages"] != nil || (obj["version"] as? Int ?? 0) >= AppConfig.currentVersion {
            if var cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
                cfg.globals.hashPasswordIfNeeded()
                cfg.save(to: url)
                return cfg
            }
        }

        // Legacy single-overlay format → migrate.
        if let old = try? JSONDecoder().decode(OverlayConfig.self, from: data) {
            let migrated = AppConfig.from(legacy: old)
            NSLog("[Overlay] Migrated legacy config.json to v\(AppConfig.currentVersion)")
            migrated.save(to: url)
            return migrated
        }

        let def = AppConfig.default
        def.save(to: url)
        return def
    }

    static func from(legacy old: OverlayConfig) -> AppConfig {
        let name = old.url?.host ?? old.url?.absoluteString ?? "Overlay"
        let page = Page(name: name, url: old.url, color: old.color, opacity: old.opacity)
        var globals = GlobalSettings(isClickThrough: old.isClickThrough,
                                     autoReloadInterval: old.autoReloadInterval,
                                     color: old.color,
                                     fakeLockScreen: old.fakeLockScreen)
        globals.hashPasswordIfNeeded()
        return AppConfig(pages: [page], globals: globals,
                         openWindows: [OpenWindowState(pageID: page.id)])
    }

    func save(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url)
        } catch {
            NSLog("AppConfig save error: \(error)")
        }
    }
}

// MARK: - Display identity helpers

extension NSScreen {
    /// The CoreGraphics display ID for this screen (not stable across reconnects).
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A stable, EDID-derived UUID string for this physical display.
    var displayUUID: String? {
        guard let id = displayID,
              let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    /// A persistable reference to this display.
    func makeDisplayRef() -> DisplayRef? {
        guard let u = displayUUID else { return nil }
        return DisplayRef(uuid: u, localizedName: localizedName)
    }

    /// Find the connected screen matching a persisted reference (UUID first, then name).
    static func screen(matching ref: DisplayRef) -> NSScreen? {
        if let s = screens.first(where: { $0.displayUUID == ref.uuid }) { return s }
        if let name = ref.localizedName {
            return screens.first(where: { $0.localizedName == name })
        }
        return nil
    }
}
