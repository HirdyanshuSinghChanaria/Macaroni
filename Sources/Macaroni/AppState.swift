import SwiftUI
import AppKit
import CoreAudio
import Combine

/// Single observable object the whole UI reads from. Owns the four feature
/// managers and mirrors their state into @Published properties.
final class AppState: ObservableObject {

    let volumeManager = VolumeManager()
    let clipboardManager = ClipboardManager(maxEntries: 200)
    let scrollInvertManager = ScrollInvertManager()
    let diskCleaner = DiskCleanerManager()
    let perAppVolume = PerAppVolumeManager()
    let network = NetworkMonitor()

    // Network — updates every second whether or not the panel is open, since
    // the menu bar readout is always on screen.
    @Published var downloadRate: Double = 0
    @Published var uploadRate: Double = 0
    @Published var networkInterface: String = "—"
    @Published var sessionReceived: UInt64 = 0
    @Published var sessionSent: UInt64 = 0
    @Published var menuBarImage: NSImage = MenuBarLabel.render(download: "0 KB/s", upload: "0 KB/s")

    // Audio
    @Published var volume: Float = 0.5
    @Published var isMuted: Bool = false
    @Published var volumeSupported: Bool = true
    @Published var outputDevices: [VolumeManager.OutputDevice] = []
    @Published var currentDeviceID: AudioDeviceID = 0

    // Per-app volume — one row per app, so gains are keyed by pid.
    @Published var audioApps: [AudioProcessLister.AudioApp] = []
    @Published var gains: [pid_t: Float] = [:]
    @Published var perAppError: String?
    @Published var audioPermissionDenied: Bool = false
    private var appPollTimer: Timer?
    private var diskSpaceTimer: Timer?
    /// Last-seen info per pid, so a controlled app keeps its row while paused.
    private var knownApps: [pid_t: AudioProcessLister.AudioApp] = [:]

    // MARK: - Feature switches
    //
    // Switching a feature off doesn't just hide its section — it stops the work
    // behind it: pollers are invalidated, taps released, event taps removed.
    // Everything defaults to on.

    @Published var showOutput: Bool { didSet { persist("feature.output", showOutput) } }
    @Published var showAppVolume: Bool {
        didSet { persist("feature.appVolume", showAppVolume); applyFeatureState() }
    }
    @Published var showClipboard: Bool {
        didSet { persist("feature.clipboard", showClipboard); applyFeatureState() }
    }
    @Published var showMouse: Bool {
        didSet { persist("feature.mouse", showMouse); applyFeatureState() }
    }
    @Published var showNetwork: Bool {
        didSet { persist("feature.network", showNetwork); applyFeatureState() }
    }
    @Published var showDisk: Bool {
        didSet { persist("feature.disk", showDisk); applyFeatureState() }
    }

    /// Absent key means "never set" — features start enabled.
    private static func flag(_ key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func persist(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Brings the running managers in line with the switches.
    private func applyFeatureState() {
        if showClipboard {
            clipboardManager.start()
        } else {
            clipboardManager.stop()
            clipboardManager.clearHistory()
        }

        if showNetwork {
            network.start()
        } else {
            network.stop()
            downloadRate = 0
            uploadRate = 0
        }
        updateMenuBarImage()

        if showAppVolume {
            refreshAudioApps()
        } else {
            // Release every tap — audio goes straight back to macOS.
            perAppVolume.stopAll()
            audioApps = []
            gains = [:]
        }

        if !showMouse, scrollInvertManager.isEnabled {
            scrollInvertManager.setEnabled(false)
            scrollInverted = false
        }

        if showDisk {
            refreshCapacity()
        } else {
            capacity = nil
            scanResult = nil
        }
    }

    // Clipboard
    @Published var clipboardHistory: [ClipboardManager.Entry] = []

    // Scroll
    @Published var scrollInverted: Bool = false
    @Published var showsAccessibilityHint: Bool = false

    // Disk
    @Published var isScanning: Bool = false
    @Published var scanResult: DiskCleanerManager.ScanResult?
    @Published var lastCleanupSummary: String?
    @Published var lastScanAt: Date?
    @Published var capacity: DiskSpace.Capacity?

    init() {
        showOutput = Self.flag("feature.output")
        showAppVolume = Self.flag("feature.appVolume")
        showClipboard = Self.flag("feature.clipboard")
        showMouse = Self.flag("feature.mouse")
        showNetwork = Self.flag("feature.network")
        showDisk = Self.flag("feature.disk")

        perAppVolume.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.perAppError = self.perAppVolume.lastError
                self.audioPermissionDenied = self.perAppVolume.permissionDenied
                self.refreshAudioApps()
            }
        }

        volumeManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshAudio() }
        }
        clipboardManager.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshClipboard() }
        }
        scrollInvertManager.onChange = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.scrollInverted = self.scrollInvertManager.isEnabled
            }
        }

        network.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.refreshNetwork() }
        }

        refreshAudio()
        // Starts only what's switched on.
        applyFeatureState()

        // Apps start and stop playing constantly, so keep the mixer live.
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.showAppVolume else { return }
            self.refreshAudioApps()
        }
        RunLoop.main.add(timer, forMode: .common)
        appPollTimer = timer

        // Free space moves slowly; no reason to stat the volume every 2s.
        let spaceTimer = Timer(timeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, self.showDisk else { return }
            self.refreshCapacity()
        }
        RunLoop.main.add(spaceTimer, forMode: .common)
        diskSpaceTimer = spaceTimer
    }

    deinit {
        appPollTimer?.invalidate()
        diskSpaceTimer?.invalidate()
        network.stop()
        perAppVolume.stopAll()
    }

    // MARK: - Network

    private func refreshNetwork() {
        downloadRate = network.downloadRate
        uploadRate = network.uploadRate
        networkInterface = network.interfaceName
        sessionReceived = network.sessionReceived
        sessionSent = network.sessionSent
        updateMenuBarImage()
    }

    private func updateMenuBarImage() {
        menuBarImage = showNetwork
            ? MenuBarLabel.render(
                download: NetworkMonitor.formatRate(downloadRate),
                upload: NetworkMonitor.formatRate(uploadRate)
              )
            : MenuBarLabel.iconOnly()
    }

    // MARK: - Audio

    func refreshAudio() {
        if let v = volumeManager.currentVolume() {
            volume = v
            volumeSupported = true
        } else {
            volumeSupported = false
        }
        isMuted = volumeManager.isMuted()
        outputDevices = volumeManager.availableOutputDevices()
        currentDeviceID = volumeManager.defaultOutputDevice()
    }

    func setVolume(_ newValue: Float) {
        volume = newValue
        volumeManager.setVolume(newValue)
    }

    func toggleMute() {
        volumeManager.setMuted(!volumeManager.isMuted())
        isMuted = volumeManager.isMuted()
    }

    func selectDevice(_ id: AudioDeviceID) {
        volumeManager.setDefaultOutputDevice(id)
        refreshAudio()
        // Active taps are wired to the old device — rebuild them onto the new one.
        perAppVolume.rebuildAll(apps: audioApps)
    }

    // MARK: - Per-app volume

    func refreshAudioApps() {
        guard showAppVolume else { return }
        var apps = perAppVolume.currentApps()
        for app in apps { knownApps[app.pid] = app }

        // Keep a row for anything we're actively controlling, even while it's
        // briefly absent from CoreAudio's list — otherwise a paused app's
        // slider vanishes while its tap is still running.
        let livePIDs = Set(apps.map(\.pid))
        for pid in perAppVolume.controlledPIDs where !livePIDs.contains(pid) {
            guard let known = knownApps[pid] else { continue }
            apps.append(AudioProcessLister.AudioApp(
                objectID: known.objectID,
                pid: known.pid,
                ownerPID: known.ownerPID,
                bundleID: known.bundleID,
                name: known.name,
                isPlaying: false
            ))
        }

        audioApps = apps
        perAppVolume.pruneDeadEngines(livePIDs: livePIDs)

        // Restores the saved level for anything that just started playing again.
        perAppVolume.update(apps: apps)
        perAppError = perAppVolume.lastError

        var current: [pid_t: Float] = [:]
        for app in apps {
            current[app.pid] = perAppVolume.userGain(for: app)
        }
        gains = current
    }

    func gain(for app: AudioProcessLister.AudioApp) -> Float {
        gains[app.pid] ?? perAppVolume.userGain(for: app)
    }

    func setGain(_ value: Float, for app: AudioProcessLister.AudioApp) {
        gains[app.pid] = value
        perAppVolume.setUserGain(value, for: app)
        perAppError = perAppVolume.lastError
        audioPermissionDenied = perAppVolume.permissionDenied
    }

    /// macOS never re-prompts once permission is denied, so the only useful
    /// thing we can offer is a shortcut to the right settings pane.
    func openAudioPrivacySettings() {
        let panes = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    func isControlled(_ app: AudioProcessLister.AudioApp) -> Bool {
        perAppVolume.isControlled(pid: app.pid)
    }

    var playingCount: Int {
        audioApps.filter(\.isPlaying).count
    }

    // MARK: - Clipboard

    private func refreshClipboard() {
        clipboardHistory = clipboardManager.history
    }

    func recopy(_ entry: ClipboardManager.Entry) {
        clipboardManager.recopy(entry)
    }

    func deleteClipboardEntry(_ entry: ClipboardManager.Entry) {
        clipboardManager.delete(entry)
    }

    func clearClipboard() {
        clipboardManager.clearHistory()
    }

    // MARK: - Scroll invert

    func toggleScrollInvert() {
        let wantEnabled = !scrollInvertManager.isEnabled
        scrollInvertManager.setEnabled(wantEnabled)
        scrollInverted = scrollInvertManager.isEnabled
        // If it wouldn't turn on, permission is the near-certain reason.
        showsAccessibilityHint = wantEnabled && !scrollInvertManager.isEnabled
    }

    // MARK: - Disk

    func refreshCapacity() {
        capacity = DiskSpace.current()
    }

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        lastCleanupSummary = nil
        diskCleaner.scan { [weak self] result in
            guard let self else { return }
            self.scanResult = result
            self.lastScanAt = Date()
            self.isScanning = false
        }
    }

    /// Deletes only what the user ticked in the review window.
    func delete(groups: [DiskCleanerManager.JunkGroup]) {
        let files = groups.flatMap { $0.files }
        guard !files.isEmpty else { return }
        let (deleted, freed, errors) = diskCleaner.delete(files)
        lastCleanupSummary = "Freed \(DiskCleanerManager.formatBytes(freed)) from \(deleted) files."
            + (errors.isEmpty ? "" : " \(errors.count) were in use.")
        scanResult = nil
        lastScanAt = nil
        refreshCapacity()
    }
}
