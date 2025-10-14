import SwiftUI

@main
struct OverlayApp: App {
    // Attach AppDelegate to SwiftUI lifecycle
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We do not present any regular SwiftUI windows; the AppDelegate creates the overlay window.
        Settings { EmptyView() }
    }
}
