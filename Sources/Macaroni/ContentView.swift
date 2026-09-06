import SwiftUI
import CoreAudio

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSettings = false

    private var anyFeatureEnabled: Bool {
        state.showOutput || state.showAppVolume || state.showClipboard
            || state.showMouse || state.showNetwork || state.showDisk
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.panelStroke)

            if showingSettings {
                settingsPanel
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if state.showOutput { outputSection }
                    if state.showAppVolume { appVolumeSection }
                    if state.showClipboard { clipboardSection }
                    if state.showMouse { inputSection }
                    if state.showNetwork { networkSection }
                    if state.showDisk { diskSection }
                    if !anyFeatureEnabled {
                        Text("Everything is switched off. Open Settings to turn something back on.")
                            .font(DS.label(10.5))
                            .foregroundStyle(DS.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                    }
                }
            }

            Divider().overlay(DS.panelStroke)
            footer
        }
        .frame(width: DS.panelWidth)
        .background(DS.panel)
        .foregroundStyle(DS.text)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.accent)
            Text("Macaroni")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)

            if state.showDisk, let capacity = state.capacity {
                Text("\(DiskSpace.format(capacity.free)) free")
                    .font(DS.mono(10.5))
                    .foregroundStyle(DS.textTertiary)
                MeterBar(segments: [(capacity.usedFraction, DS.accent)], height: 4)
                    .frame(width: 42)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DS.headerTint)
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader("OUTPUT")

            Menu {
                ForEach(state.outputDevices) { device in
                    Button {
                        state.selectDevice(device.id)
                    } label: {
                        if device.id == state.currentDeviceID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.textSecondary)
                    Text(currentDeviceName)
                        .font(DS.label())
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(DS.control)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DS.controlStroke, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            // Devices that expose no software volume (many Bluetooth ones)
            // get no dead slider — just the mute control that still applies.
            HStack(spacing: 9) {
                if state.volumeSupported {
                    ThinSlider(value: Binding(
                        get: { Double(state.volume) },
                        set: { state.setVolume(Float($0)) }
                    ))
                    Text("\(Int(state.volume * 100))%")
                        .font(DS.mono())
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 27, alignment: .trailing)
                }
                IconButton(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.slash") {
                    state.toggleMute()
                }
                if !state.volumeSupported {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var currentDeviceName: String {
        state.outputDevices.first { $0.id == state.currentDeviceID }?.name ?? "Output"
    }

    // MARK: - App volume (mixer)

    private var appVolumeSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "APP VOLUME") {
                HStack(spacing: 7) {
                    Text("\(state.playingCount) ACTIVE")
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.textFaint)
                    Button {
                        state.refreshAudioApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if state.audioApps.isEmpty {
                emptyRow("Nothing is playing audio.")
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(state.audioApps) { app in
                            MixerRow(app: app)
                        }
                    }
                }
                .frame(height: min(CGFloat(state.audioApps.count) * 29 - 5, 140))
            }

            if state.audioPermissionDenied {
                permissionNotice
            } else if let error = state.perAppError {
                Text(error)
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Shown instead of failing silently. macOS won't ask again after a denial,
    /// so the only thing that helps is pointing at the settings pane.
    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.amber)
                Text(state.perAppError ?? "macOS is blocking audio access, so app volume can't work.")
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PanelButton(title: "Open Privacy Settings", systemImage: "gear", prominent: true) {
                state.openAudioPrivacySettings()
            }
        }
        .padding(8)
        .background(DS.amber.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(DS.amber.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "CLIPBOARD") {
                HStack(spacing: 7) {
                    Text("\(state.clipboardHistory.count)")
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.textFaint)
                    if !state.clipboardHistory.isEmpty {
                        Button("CLEAR") { state.clearClipboard() }
                            .buttonStyle(.plain)
                            .font(DS.label(9.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }

            if state.clipboardHistory.isEmpty {
                emptyRow("Copy something and it lands here.")
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(state.clipboardHistory.enumerated()), id: \.element.id) { index, entry in
                            ClipboardRow(index: index + 1, entry: entry)
                        }
                    }
                }
                .frame(height: min(CGFloat(state.clipboardHistory.count) * 22, 132))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("INPUT")

            HStack(spacing: 8) {
                Image(systemName: "computermouse")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textSecondary)
                Text("Invert scroll direction")
                    .font(DS.label())
                Spacer(minLength: 4)
                PillToggle(isOn: Binding(
                    get: { state.scrollInverted },
                    set: { _ in state.toggleScrollInvert() }
                ))
            }
            .frame(height: 24)

            if state.showsAccessibilityHint {
                Text("Needs Accessibility permission — grant it in System Settings, then relaunch.")
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "NETWORK") {
                Text(state.networkInterface.uppercased())
                    .font(DS.mono(9.5))
                    .foregroundStyle(DS.textFaint)
            }

            throughputRow(
                symbol: "arrow.down",
                tint: DS.accent,
                rate: state.downloadRate,
                total: state.sessionReceived
            )
            throughputRow(
                symbol: "arrow.up",
                tint: DS.green,
                rate: state.uploadRate,
                total: state.sessionSent
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func throughputRow(symbol: String, tint: Color, rate: Double, total: UInt64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(NetworkMonitor.formatRate(rate))
                .font(DS.mono(11))
                .foregroundStyle(rate > 1_024 ? DS.text : DS.textSecondary)
            Spacer(minLength: 4)
            Text(NetworkMonitor.formatTotal(total))
                .font(DS.mono(9.5))
                .foregroundStyle(DS.textFaint)
            Text("this session")
                .font(DS.label(9.5))
                .foregroundStyle(DS.textFaint)
        }
        .frame(height: 18)
    }

    // MARK: - Disk

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "DISK") {
                if let scannedAt = state.lastScanAt {
                    Text("SCANNED \(DS.shortAge(scannedAt)) AGO")
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.textFaint)
                }
            }

            if let capacity = state.capacity {
                // The junk sits as its own segment right after used space, so
                // you can see what reclaiming it would actually buy you.
                MeterBar(segments: diskSegments(capacity), height: 6)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(DiskSpace.format(capacity.free)) free")
                        .font(DS.mono())
                        .foregroundStyle(DS.textSecondary)
                    Text("/ \(DiskSpace.format(capacity.total))")
                        .font(DS.label(10.5))
                        .foregroundStyle(DS.textFaint)
                    Spacer(minLength: 4)
                    if let result = state.scanResult {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(DS.amber)
                                .frame(width: 6, height: 6)
                            Text("\(DiskCleanerManager.formatBytes(result.totalSize)) junk")
                                .font(DS.mono())
                                .foregroundStyle(DS.amber)
                        }
                    }
                }
            }

            if state.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(DS.label(10.5)).foregroundStyle(DS.textTertiary)
                }
                .frame(height: 24)
            } else if let result = state.scanResult {
                HStack(spacing: 6) {
                    PanelButton(
                        title: "Review \(result.fileCount.formatted()) files",
                        systemImage: "folder",
                        prominent: true
                    ) {
                        ReviewWindowController.shared.show(state: state)
                    }
                    IconButton(systemName: "arrow.clockwise") { state.startScan() }
                }
            } else {
                PanelButton(title: "Scan for junk files", systemImage: "magnifyingglass") {
                    state.startScan()
                }
                if let summary = state.lastCleanupSummary {
                    Text(summary)
                        .font(DS.label(9.5))
                        .foregroundStyle(DS.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Caches, logs, temp files, Trash and leftover installers older than 7 days. Nothing is deleted without review.")
                        .font(DS.label(9.5))
                        .foregroundStyle(DS.textFaint)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }

    private func diskSegments(_ capacity: DiskSpace.Capacity) -> [(Double, Color)] {
        let junk = Double(state.scanResult?.totalSize ?? 0) / Double(capacity.total)
        let used = max(0, capacity.usedFraction - junk)
        return [(used, Color.white.opacity(0.55)), (junk, DS.amber)]
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Doubles as the way back out of settings.
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showingSettings.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingSettings ? "chevron.left" : "gearshape")
                        .font(.system(size: 10, weight: .medium))
                    Text(showingSettings ? "Back" : "Settings")
                        .font(DS.label(10.5))
                }
                .foregroundStyle(showingSettings ? DS.accent : DS.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("v1.1")
                .font(DS.mono(9.5))
                .foregroundStyle(DS.textFaint)
            Text("·")
                .font(DS.label(9.5))
                .foregroundStyle(DS.textFaint)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(DS.label(10.5))
                .foregroundStyle(DS.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DS.footerTint)
    }

    // MARK: - Settings

    /// Each switch stops the work behind the feature, not just its section —
    /// the captions say so, because "off" that keeps polling isn't off.
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("SHOW IN PANEL")

            featureToggle(
                icon: "speaker.wave.2",
                title: "Output",
                detail: "Master volume, mute and device switching.",
                isOn: $state.showOutput
            )
            featureToggle(
                icon: "slider.vertical.3",
                title: "App volume",
                detail: "Per-app mixer. Off releases any audio taps immediately.",
                isOn: $state.showAppVolume
            )
            featureToggle(
                icon: "doc.on.clipboard",
                title: "Clipboard history",
                detail: "Off stops the pasteboard poller and clears stored entries.",
                isOn: $state.showClipboard
            )
            featureToggle(
                icon: "computermouse",
                title: "Mouse",
                detail: "Scroll inversion. Off removes the event tap.",
                isOn: $state.showMouse
            )
            featureToggle(
                icon: "arrow.up.arrow.down",
                title: "Network speed",
                detail: "Off stops the sampler and shrinks the menu bar item to just the icon.",
                isOn: $state.showNetwork
            )
            featureToggle(
                icon: "internaldrive",
                title: "Disk",
                detail: "Free space readout and the junk file scanner.",
                isOn: $state.showDisk
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func featureToggle(
        icon: String,
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isOn.wrappedValue ? DS.accent : DS.textTertiary)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.label())
                Text(detail)
                    .font(DS.label(9.5))
                    .foregroundStyle(DS.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            PillToggle(isOn: isOn)
                .padding(.top, 1)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(DS.label(10.5))
            .foregroundStyle(DS.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 24, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.white.opacity(0.09))
            )
    }
}

// MARK: - Mixer row

/// One app in the mixer: playing indicator, icon, name, its own slider.
private struct MixerRow: View {
    @EnvironmentObject private var state: AppState
    let app: AudioProcessLister.AudioApp

    private var gain: Float { state.gain(for: app) }
    private var turnedDown: Bool { gain < 0.999 }

    var body: some View {
        HStack(spacing: 8) {
            if app.isPlaying {
                PlayingIndicator()
            } else {
                Circle()
                    .fill(DS.textTertiary)
                    .frame(width: 3, height: 3)
                    .frame(width: 9, height: 11)
            }

            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 15, height: 15)
            }

            Text(app.name)
                .font(DS.label())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 68, alignment: .leading)

            ThinSlider(
                value: Binding(
                    get: { Double(state.gain(for: app)) },
                    set: { state.setGain(Float($0), for: app) }
                ),
                tint: turnedDown ? DS.accent : Color.white.opacity(0.55),
                trackHeight: 3,
                knobSize: 9
            )

            Text("\(Int(gain * 100))%")
                .font(DS.mono())
                .foregroundStyle(turnedDown ? DS.accent : DS.textSecondary)
                .frame(width: 27, alignment: .trailing)
        }
        .frame(height: 24)
        .opacity(app.isPlaying ? 1 : 0.6)
    }
}

// MARK: - Clipboard row

private struct ClipboardRow: View {
    @EnvironmentObject private var state: AppState
    @State private var hovering = false
    let index: Int
    let entry: ClipboardManager.Entry

    private var preview: String {
        let flattened = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "(whitespace)" : flattened
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index))
                .font(DS.mono(9.5))
                .foregroundStyle(hovering ? DS.accent : DS.textFaint)
                .frame(width: 13, alignment: .leading)

            Text(preview)
                .font(DS.mono())
                .foregroundStyle(DS.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                Button {
                    state.recopy(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy again")

                Button {
                    state.deleteClipboardEntry(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            } else {
                Text(DS.shortAge(entry.date))
                    .font(DS.mono(9.5))
                    .foregroundStyle(DS.textFaint)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 21)
        .background(hovering ? DS.accent.opacity(0.11) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.recopy(entry) }
    }
}
