import Foundation
import CoreAudio
import AVFoundation

/// Owns one `AppAudioEngine` per app whose volume has actually been changed.
///
/// Apps left at 100% are deliberately *not* tapped — tapping reroutes audio
/// through us, so we only do it when there's a reason to. Setting an app back
/// to 100% tears its engine down and hands audio straight back to macOS.
final class PerAppVolumeManager {

    /// Gains keyed by bundle id, so Spotify stays where you put it next launch.
    private var savedGains: [String: Float] {
        get { (UserDefaults.standard.dictionary(forKey: "perAppGains") as? [String: Float]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "perAppGains") }
    }

    private var userGains: [pid_t: Float] = [:]
    private var engines: [pid_t: AppAudioEngine] = [:]

    /// Surfaced to the UI when a tap fails (almost always a permission issue).
    private(set) var lastError: String?

    /// True once we know macOS won't let us read app audio. The UI turns this
    /// into a "grant permission" prompt rather than silently doing nothing.
    private(set) var permissionDenied = false

    /// Called when something changed behind the UI's back — a tap was released
    /// by the watchdog, or a permission answer arrived.
    var onChange: (() -> Void)?

    // MARK: - Reading

    func currentApps() -> [AudioProcessLister.AudioApp] {
        AudioProcessLister.currentApps()
    }

    var controlledPIDs: Set<pid_t> { Set(engines.keys) }

    func isControlled(pid: pid_t) -> Bool { engines[pid] != nil }

    /// The level set for this app: whatever's live, else what was saved for its
    /// bundle id last time, else full volume.
    func userGain(for app: AudioProcessLister.AudioApp) -> Float {
        if let gain = userGains[app.pid] { return gain }
        if let bundleID = app.bundleID, let saved = savedGains[bundleID] {
            userGains[app.pid] = saved
            return saved
        }
        return 1.0
    }

    // MARK: - Writing

    func setUserGain(_ value: Float, for app: AudioProcessLister.AudioApp) {
        let clamped = max(0, min(1, value))
        userGains[app.pid] = clamped

        if let bundleID = app.bundleID {
            var gains = savedGains
            if clamped >= 0.999 {
                gains.removeValue(forKey: bundleID)
            } else {
                gains[bundleID] = clamped
            }
            savedGains = gains
        }

        apply(to: app)
    }

    /// Called every refresh so an app that was turned down and has just started
    /// playing again comes back at the level you left it.
    func update(apps: [AudioProcessLister.AudioApp]) {
        for app in apps where app.isPlaying {
            apply(to: app)
        }
    }

    private func apply(to app: AudioProcessLister.AudioApp) {
        let gain = userGain(for: app)

        // Back at full volume — stop intercepting entirely.
        guard gain < 0.999 else {
            engines[app.pid]?.stop()
            engines[app.pid] = nil
            return
        }

        if let engine = engines[app.pid] {
            engine.gain = gain
            return
        }

        // Check before tapping. Creating a tap without permission still MUTES
        // the app — it just never delivers audio — so tapping first and asking
        // later silently kills the app's sound.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // The one prompt macOS will ever show. Retry once answered.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.permissionDenied = false
                        self.apply(to: app)
                    } else {
                        self.releaseAndReset(app, reason: .denied)
                    }
                    self.onChange?()
                }
            }
            return
        default:
            // Already denied. macOS never re-prompts, so don't try — say so.
            releaseAndReset(app, reason: .denied)
            return
        }

        let engine = AppAudioEngine(pid: app.pid, processObjectID: app.objectID, gain: gain)
        do {
            try engine.start()
            engines[app.pid] = engine
            lastError = nil
            permissionDenied = false
            watchForStarvation(app, engine: engine)
        } catch {
            engine.stop()
            lastError = error.localizedDescription
        }
    }

    private enum ReleaseReason {
        case denied
        case starved
    }

    /// Puts an app back exactly as it was: tap released (so it un-mutes), gain
    /// back to 100%, saved level forgotten.
    private func releaseAndReset(_ app: AudioProcessLister.AudioApp, reason: ReleaseReason) {
        engines[app.pid]?.stop()
        engines[app.pid] = nil
        userGains[app.pid] = 1.0
        if let bundleID = app.bundleID {
            var gains = savedGains
            gains.removeValue(forKey: bundleID)
            savedGains = gains
        }

        permissionDenied = true
        lastError = reason == .denied
            ? "macOS is blocking audio access, so app volume can't work. Grant it in System Settings, then try again."
            : "Couldn't read \(app.name)'s audio, so its volume was restored to 100%. This usually means audio permission is blocked."
    }

    /// The safety net. A tap can be created successfully, mute the app, and then
    /// deliver nothing at all — that's what a blocked tap looks like. If no real
    /// audio arrives shortly after starting, release it so nothing stays muted.
    private func watchForStarvation(_ app: AudioProcessLister.AudioApp, engine: AppAudioEngine) {
        guard app.isPlaying else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak engine] in
            guard let self, let engine, self.engines[app.pid] === engine else { return }
            guard engine.activeFrames == 0 else { return }
            self.releaseAndReset(app, reason: .starved)
            self.onChange?()
        }
    }

    /// Drops engines only for processes that have actually EXITED.
    ///
    /// Absence from CoreAudio's process list is not death — an app that pauses
    /// for a moment disappears from it and comes back. Tearing the tap down
    /// then rebuilding it seconds later makes the audio pop, and on Bluetooth
    /// it can force a device profile switch each time.
    func pruneDeadEngines(livePIDs: Set<pid_t>) {
        for (pid, engine) in engines where !livePIDs.contains(pid) {
            // kill(pid, 0) probes existence without sending anything; EPERM
            // means it exists but belongs to someone else.
            let exists = kill(pid, 0) == 0 || errno == EPERM
            guard !exists else { continue }
            engine.stop()
            engines[pid] = nil
            userGains[pid] = nil
        }
    }

    /// The aggregate device is bound to whichever output device existed when it
    /// was built, so switching outputs means rebuilding every active engine.
    func rebuildAll(apps: [AudioProcessLister.AudioApp]) {
        for (_, engine) in engines { engine.stop() }
        engines.removeAll()
        for app in apps {
            apply(to: app)
        }
    }

    func stopAll() {
        for (_, engine) in engines { engine.stop() }
        engines.removeAll()
    }
}
