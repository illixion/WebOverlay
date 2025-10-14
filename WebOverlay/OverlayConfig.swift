import Foundation
import AppKit

/// Basic configuration for the overlay HUD
struct OverlayConfig: Codable {
    var url: URL
    var opacity: CGFloat
    var isClickThrough: Bool
    var autoReloadInterval: TimeInterval?

    static let `default` = OverlayConfig(
        url: URL(string: "https://www.apple.com")!,
        opacity: 0.85,
        isClickThrough: true,
        autoReloadInterval: nil
    )
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
