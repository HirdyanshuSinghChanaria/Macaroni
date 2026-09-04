import SwiftUI
import AppKit

/// Macaroni runs as a menu-bar-only app. Using MenuBarExtra with the
/// `.window` style (instead of a classic NSMenu) means the panel stays open
/// while you click toggles, drag the volume slider, or pick clipboard
/// entries — a normal NSMenu dismisses itself on every click.
@main
struct MacaroniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
        } label: {
            // Rendered image rather than a symbol: it carries the live
            // throughput readout beside the icon. See MenuBarLabel.
            Image(nsImage: state.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no Cmd+Tab entry — same effect as LSUIElement=true.
        NSApp.setActivationPolicy(.accessory)
    }
}
