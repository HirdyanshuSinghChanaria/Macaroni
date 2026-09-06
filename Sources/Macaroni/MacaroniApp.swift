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
        retireOlderInstances()
    }

    /// Without this you get two menu bar icons — each with its own pollers and
    /// its own audio taps — by launching the app while a copy is still running,
    /// which is exactly what happens when someone updates it.
    ///
    /// The newest launch wins, so opening a freshly updated build replaces the
    /// old one rather than sitting beside it.
    private func retireOlderInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = NSRunningApplication.current.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != mine {
            other.terminate()
        }
    }
}
