import SwiftUI
import AppKit

/// The "see exactly what you're about to delete" window. Nothing is removed
/// from here without ticking a location and confirming.
struct DiskReviewView: View {
    @ObservedObject var state: AppState

    /// Everything starts unticked on purpose — no accidental "select all and nuke".
    @State private var selected: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @State private var filter: String? = nil
    @State private var showingConfirm = false

    private var allGroups: [DiskCleanerManager.JunkGroup] {
        state.scanResult?.groups ?? []
    }

    private var groups: [DiskCleanerManager.JunkGroup] {
        guard let filter else { return allGroups }
        return allGroups.filter { $0.category == filter }
    }

    private var categories: [String] {
        var seen: [String] = []
        for group in allGroups where !seen.contains(group.category) {
            seen.append(group.category)
        }
        return seen
    }

    private var selectedGroups: [DiskCleanerManager.JunkGroup] {
        allGroups.filter { selected.contains($0.id) }
    }

    private var selectedSize: Int64 { selectedGroups.reduce(0) { $0 + $1.totalSize } }
    private var selectedCount: Int { selectedGroups.reduce(0) { $0 + $1.fileCount } }
    private var largestGroup: Int64 { max(groups.first?.totalSize ?? 1, 1) }

    var body: some View {
        VStack(spacing: 0) {
            summaryStrip
            Divider().overlay(DS.panelStroke)
            columnHeader
            rows
            Divider().overlay(DS.panelStroke)
            footer
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(DS.panel)
        .foregroundStyle(DS.text)
        .alert("Delete \(selectedCount.formatted()) files?", isPresented: $showingConfirm) {
            Button("Delete", role: .destructive) {
                state.delete(groups: selectedGroups)
                ReviewWindowController.shared.close()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(DiskCleanerManager.formatBytes(selectedSize)) from \(selectedGroups.count) locations. It can't be undone.")
        }
    }

    // MARK: - Summary

    private var summaryStrip: some View {
        HStack(spacing: 14) {
            statBlock(
                value: DiskCleanerManager.formatBytes(state.scanResult?.totalSize ?? 0),
                label: "RECLAIMABLE",
                tint: DS.amber
            )
            Rectangle().fill(DS.panelStroke).frame(width: 1, height: 30)
            statBlock(
                value: (state.scanResult?.fileCount ?? 0).formatted(),
                label: "FILES · \(allGroups.count) LOCATIONS",
                tint: DS.text.opacity(0.9)
            )

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                chip(title: "All", active: filter == nil) { filter = nil }
                ForEach(categories, id: \.self) { category in
                    chip(title: category, active: filter == category) { filter = category }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func statBlock(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 9.5))
                .kerning(0.4)
                .foregroundStyle(DS.textTertiary)
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.label(10.5))
                .foregroundStyle(active ? DS.accent : DS.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(active ? DS.accentSoft : DS.control)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(active ? DS.accent.opacity(0.3) : DS.controlStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Table

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 13)
            Color.clear.frame(width: 10)
            Text("LOCATION").frame(maxWidth: .infinity, alignment: .leading)
            Text("FILES").frame(width: 86, alignment: .trailing)
            Text("SIZE").frame(width: 74, alignment: .trailing)
            Text("SHARE").frame(width: 130, alignment: .leading)
            Color.clear.frame(width: 16)
        }
        .font(.system(size: 9.5))
        .kerning(0.5)
        .foregroundStyle(DS.textTertiary)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Color.black.opacity(0.16))
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    GroupRow(
                        group: group,
                        isSelected: selected.contains(group.id),
                        isExpanded: expanded.contains(group.id),
                        share: Double(group.totalSize) / Double(largestGroup),
                        toggleSelected: {
                            if selected.contains(group.id) { selected.remove(group.id) }
                            else { selected.insert(group.id) }
                        },
                        toggleExpanded: {
                            if expanded.contains(group.id) { expanded.remove(group.id) }
                            else { expanded.insert(group.id) }
                        }
                    )
                    if expanded.contains(group.id) {
                        FileList(group: group)
                    }
                    Divider().overlay(Color.white.opacity(0.045))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if selected.isEmpty {
                Text("Nothing selected")
                    .font(DS.label(11))
                    .foregroundStyle(DS.textTertiary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DiskCleanerManager.formatBytes(selectedSize))
                        .font(.system(size: 13, design: .monospaced))
                    Text("selected · \(selectedCount.formatted()) files in \(selectedGroups.count) locations")
                        .font(DS.label(11))
                        .foregroundStyle(DS.textTertiary)
                }
            }

            Spacer()

            Button("Select all") { selected = Set(groups.map(\.id)) }
                .buttonStyle(.plain)
                .font(DS.label(11))
                .foregroundStyle(DS.textSecondary)
            Rectangle().fill(DS.panelStroke).frame(width: 1, height: 11)
            Button("None") { selected.removeAll() }
                .buttonStyle(.plain)
                .font(DS.label(11))
                .foregroundStyle(DS.textSecondary)

            Button("Close") { ReviewWindowController.shared.close() }
                .buttonStyle(.plain)
                .font(DS.label(11.5))
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background(DS.control)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6).stroke(DS.controlStroke, lineWidth: 1)
                )

            Button {
                showingConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(selected.isEmpty
                         ? "Delete"
                         : "Delete \(DiskCleanerManager.formatBytes(selectedSize))")
                        .font(DS.label(11.5))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background(selected.isEmpty ? DS.danger.opacity(0.35) : DS.danger)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: - Row

private struct GroupRow: View {
    let group: DiskCleanerManager.JunkGroup
    let isSelected: Bool
    let isExpanded: Bool
    let share: Double
    let toggleSelected: () -> Void
    let toggleExpanded: () -> Void

    @State private var hovering = false

    private var displayPath: String {
        (group.containerURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Installers in Downloads are the one group that can hold something you
    /// actually wanted to keep, so it gets flagged.
    private var needsCare: Bool {
        group.category.contains("Installers")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleSelected) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(isSelected ? DS.accent : DS.control)
                    .frame(width: 13, height: 13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5)
                            .stroke(isSelected ? Color.clear : Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(DS.panel)
                        }
                    }
            }
            .buttonStyle(.plain)

            Button(action: toggleExpanded) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isExpanded ? DS.textSecondary : DS.textTertiary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(DS.label(12))
                        .lineLimit(1)
                    if needsCare {
                        Text("CHECK FIRST")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.amber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(DS.amber.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(displayPath)
                    .font(DS.mono(9.5))
                    .foregroundStyle(DS.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(group.fileCount.formatted())
                .font(DS.mono(11))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 86, alignment: .trailing)

            Text(DiskCleanerManager.formatBytes(group.totalSize))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DS.text.opacity(0.92))
                .frame(width: 74, alignment: .trailing)

            MeterBar(
                segments: [(share, isSelected ? DS.amber : DS.amber.opacity(0.65))],
                height: 5
            )
            .frame(width: 130)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([group.containerURL])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textTertiary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(isSelected ? DS.accent.opacity(0.07) : (hovering ? Color.white.opacity(0.03) : Color.clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - Expanded file list

private struct FileList: View {
    let group: DiskCleanerManager.JunkGroup

    /// Some cache folders hold tens of thousands of files; rendering them all
    /// helps nobody, so show the biggest offenders.
    private var shown: [DiskCleanerManager.JunkFile] {
        Array(group.files.sorted { $0.size > $1.size }.prefix(200))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { file in
                HStack(spacing: 10) {
                    Text(file.url.lastPathComponent)
                        .font(DS.mono(10))
                        .foregroundStyle(DS.text.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(file.modified, style: .date)
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.textFaint)
                        .frame(width: 110, alignment: .trailing)
                    Text(DiskCleanerManager.formatBytes(file.size))
                        .font(DS.mono(10))
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 74, alignment: .trailing)
                }
                .padding(.leading, 68)
                .padding(.trailing, 40)
                .frame(height: 20)
            }

            if group.files.count > shown.count {
                Text("+ \((group.files.count - shown.count).formatted()) more files")
                    .font(DS.mono(9.5))
                    .foregroundStyle(DS.textFaint)
                    .padding(.leading, 68)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: - Window

/// Hosts the review window. A singleton so the window isn't deallocated the
/// moment the menu bar panel closes.
final class ReviewWindowController {
    static let shared = ReviewWindowController()
    private var window: NSWindow?

    func show(state: AppState) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DiskReviewView(state: state))
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "Junk Files"
        newWindow.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.backgroundColor = NSColor(red: 0.102, green: 0.102, blue: 0.114, alpha: 1)
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(NSSize(width: 880, height: 580))
        newWindow.center()
        window = newWindow

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
