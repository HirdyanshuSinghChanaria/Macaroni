import Cocoa
import ApplicationServices

/// Inverts mouse scroll-wheel direction independently of macOS's own
/// "Natural Scrolling" setting, by tapping the HID event stream and flipping
/// the delta of scroll events before they reach any app.
///
/// This requires the app to be granted Accessibility permission (System
/// Settings > Privacy & Security > Accessibility), because CGEventTap with
/// listenOnly:false (needed to *modify* events, not just observe them)
/// requires it.
final class ScrollInvertManager {

    private(set) var isEnabled = false {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Prompts the user (via the standard system dialog) if permission hasn't
    /// been granted yet. Returns the current trust state.
    @discardableResult
    func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: prompt]
        return AXIsProcessTrustedWithOptions(options)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard ensureAccessibilityPermission(prompt: true) else {
                isEnabled = false
                return
            }
            startTap()
        } else {
            stopTap()
        }
        isEnabled = enabled
    }

    private func startTap() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        // The callback must be a C function pointer, so we route through a
        // global helper and stash `self` in the tap's `userInfo`.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .scrollWheel, let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<ScrollInvertManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.invert(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            // Most likely cause: Accessibility permission not actually granted yet
            // (the toggle in System Settings can lag one relaunch behind).
            NSLog("Macaroni: failed to create scroll event tap — check Accessibility permission")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func invert(_ event: CGEvent) {
        // Flip both the "line" delta (used by most apps) and the pixel-precise
        // delta (used by trackpad-aware scroll views) on both axes.
        for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2] {
            let value = event.getDoubleValueField(field)
            event.setDoubleValueField(field, value: -value)
        }
        for field: CGEventField in [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
            let value = event.getDoubleValueField(field)
            event.setDoubleValueField(field, value: -value)
        }
        for field: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            let value = event.getDoubleValueField(field)
            event.setDoubleValueField(field, value: -value)
        }
    }
}
