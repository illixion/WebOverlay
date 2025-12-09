import Foundation
import AppKit

/// Configuration for fake lock screen feature
struct FakeLockScreenConfig: Codable {
    var enable: Bool
    var password: String
    var message: String?
    var secure: Bool

    static let `default` = FakeLockScreenConfig(
        enable: false,
        password: "",
        message: nil,
        secure: false
    )
}

/// Basic configuration for the overlay HUD
struct OverlayConfig: Codable {
    var url: URL?
    var color: String?
    var opacity: CGFloat
    var isClickThrough: Bool
    var autoReloadInterval: TimeInterval?
    var fakeLockScreen: FakeLockScreenConfig?

    static let `default` = OverlayConfig(
        url: URL(string: "https://www.apple.com")!,
        color: nil,
        opacity: 0.3,
        isClickThrough: true,
        autoReloadInterval: nil,
        fakeLockScreen: nil
    )

    enum CodingKeys: String, CodingKey {
        case url, color, opacity, isClickThrough, autoReloadInterval, fakeLockScreen
    }

    init(url: URL? = nil, color: String? = nil, opacity: CGFloat = 0.3, isClickThrough: Bool = true, autoReloadInterval: TimeInterval? = nil, fakeLockScreen: FakeLockScreenConfig? = nil) {
        self.url = url
        self.color = color
        self.opacity = opacity
        self.isClickThrough = isClickThrough
        self.autoReloadInterval = autoReloadInterval
        self.fakeLockScreen = fakeLockScreen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.3
        isClickThrough = try container.decodeIfPresent(Bool.self, forKey: .isClickThrough) ?? true
        autoReloadInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .autoReloadInterval)
        fakeLockScreen = try container.decodeIfPresent(FakeLockScreenConfig.self, forKey: .fakeLockScreen)
    }

    /// Returns the parsed NSColor from the hex color string, if valid
    var parsedColor: NSColor? {
        guard let hex = color else { return nil }
        return NSColor(hexString: hex)
    }

    /// Whether this config uses color mode instead of URL mode
    var isColorMode: Bool {
        return color != nil && parsedColor != nil
    }

    /// Whether the fake lock screen mode is enabled
    var isLockScreenMode: Bool {
        return fakeLockScreen?.enable == true
    }

    /// Whether secure mode is enabled (captures input, disables hotkeys)
    var isSecureMode: Bool {
        return isLockScreenMode && fakeLockScreen?.secure == true
    }
}

extension NSColor {
    /// Initialize NSColor from a hex string (e.g., "#FF0000", "FF0000", "#F00", "F00")
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        // Support shorthand hex (e.g., "F00" -> "FF0000")
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        guard hex.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgbValue) else { return nil }

        let r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

extension OverlayConfig {
    static func load(from url: URL) -> OverlayConfig {
        guard let data = try? Data(contentsOf: url) else {
            // File doesn't exist, create it with default config
            let defaultConfig = OverlayConfig.default
            defaultConfig.save(to: url)
            return defaultConfig
        }
        return (try? JSONDecoder().decode(OverlayConfig.self, from: data)) ?? .default
    }

    func save(to url: URL) {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url)
        } catch {
            NSLog("OverlayConfig save error: \(error)")
        }
    }
}
