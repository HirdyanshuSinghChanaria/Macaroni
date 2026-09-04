import Foundation
import CoreAudio
import AppKit

/// Enumerates the processes CoreAudio knows about, so we can show a dropdown
/// of "apps currently playing audio". Process objects are a macOS 14 addition
/// to the HAL — each running app that touches audio gets an AudioObjectID.
enum AudioProcessLister {

    struct AudioApp: Identifiable, Equatable {
        /// The CoreAudio process object — this is what a tap is created against.
        let objectID: AudioObjectID
        let pid: pid_t
        /// The user-facing app this process belongs to. For a browser's audio
        /// helper this is the browser itself; usually the same as `pid`.
        let ownerPID: pid_t
        let bundleID: String?
        let name: String
        let isPlaying: Bool

        var id: pid_t { pid }

        var icon: NSImage? {
            NSRunningApplication(processIdentifier: ownerPID)?.icon
        }
    }

    /// All processes currently running audio *output*, newest info each call.
    /// `includeIdle` also returns apps that have an audio session open but
    /// aren't producing sound this instant (e.g. a paused video).
    static func currentApps(includeIdle: Bool = true) -> [AudioApp] {
        processObjectIDs().compactMap { objectID in
            let pid = pidFor(objectID)
            guard pid > 0 else { return nil }

            let playing = boolProperty(objectID, kAudioProcessPropertyIsRunningOutput)
            let hasSession = playing || boolProperty(objectID, kAudioProcessPropertyIsRunning)
            guard playing || (includeIdle && hasSession) else { return nil }

            guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

            // Browsers and Electron apps play audio from a helper process, which
            // has no app identity of its own — so walk up to the app that owns it.
            let owner = ownerApplication(for: pid)
            let ownerPID = owner?.processIdentifier ?? pid
            let bundleID = owner?.bundleIdentifier
                ?? stringProperty(objectID, kAudioProcessPropertyBundleID)

            guard let name = owner?.localizedName ?? bundleID.map(prettify) else { return nil }

            return AudioApp(
                objectID: objectID,
                pid: pid,
                ownerPID: ownerPID,
                bundleID: bundleID,
                name: name,
                isPlaying: playing
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Process identity

    /// The app a process belongs to. `NSRunningApplication` only knows about
    /// real apps, so for a helper (Brave's audio process, an Electron renderer)
    /// we climb the parent chain until we find one.
    private static func ownerApplication(for pid: pid_t) -> NSRunningApplication? {
        var current = pid
        // Chromium nests two or three deep; five is plenty and bounds the loop.
        for _ in 0..<5 {
            if let app = NSRunningApplication(processIdentifier: current) { return app }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Last-resort display name from a bundle id: "com.brave.Browser" → "Brave".
    private static func prettify(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 2 else { return bundleID }
        return parts[1].capitalized
    }

    // MARK: - HAL plumbing

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func pidFor(_ objectID: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    private static func boolProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func stringProperty(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
