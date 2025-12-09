import Foundation
import AppKit

/// Basic configuration for the overlay HUD
struct OverlayConfig: Codable {
    var url: URL?
    var color: String?
    var opacity: CGFloat
    var isClickThrough: Bool
    var autoReloadInterval: TimeInterval?

    static let `default` = OverlayConfig(
        url: URL(string: "https://www.apple.com")!,
        color: nil,
        opacity: 0.85,
        isClickThrough: true,
        autoReloadInterval: nil
    )

    /// Returns the parsed NSColor from the hex color string, if valid
    var parsedColor: NSColor? {
        guard let hex = color else { return nil }
        return NSColor(hexString: hex)
    }

    /// Whether this config uses color mode instead of URL mode
    var isColorMode: Bool {
        return color != nil && parsedColor != nil
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
        guard let data = try? Data(contentsOf: url) else { return .default }
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
