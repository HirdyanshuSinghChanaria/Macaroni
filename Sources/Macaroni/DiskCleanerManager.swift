import Foundation

/// Scans a safe, well-known set of junk locations (your own user caches/logs,
/// the system temp dir, and Trash) for files older than a threshold, and
/// reports them **grouped by the app/folder they belong to** so you can see
/// exactly what you'd be deleting before anything is removed.
///
/// Deliberately scoped to *your own* ~/Library, not other apps' sandboxed
/// containers or system-owned locations — deleting those needs Full Disk
/// Access and can break things, so it's left out on purpose.
final class DiskCleanerManager {

    struct JunkFile: Identifiable {
        let id = UUID()
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// Files bundled by which app / folder they came from, e.g.
    /// "Caches › com.google.Chrome" — this is the unit you review and select.
    struct JunkGroup: Identifiable {
        let id = UUID()
        /// Which root it came from — "Caches", "Logs", "Trash", … — used for
        /// the filter chips in the review window.
        let category: String
        /// Just the app/folder name, e.g. "Homebrew".
        let name: String
        let containerURL: URL
        let files: [JunkFile]

        var label: String { name == category ? category : "\(category) › \(name)" }
        var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
        var fileCount: Int { files.count }
    }

    struct ScanResult {
        let groups: [JunkGroup]
        var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
        var fileCount: Int { groups.reduce(0) { $0 + $1.fileCount } }
    }

    /// Days since last modified before a file counts as "junk".
    var minimumAgeDays: Int = 7

    private struct ScanRoot {
        let url: URL
        let displayName: String
        /// Walk subfolders, or only look at the top level?
        var recursive: Bool = true
        /// If set, only files with these extensions count.
        var extensions: Set<String>? = nil
        /// Split into one group per subfolder (true) or keep as a single group (false).
        var groupBySubfolder: Bool = true
    }

    private var scanRoots: [ScanRoot] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [
            ScanRoot(url: home.appendingPathComponent("Library/Caches"), displayName: "Caches"),
            ScanRoot(url: home.appendingPathComponent("Library/Logs"), displayName: "Logs"),
            ScanRoot(url: URL(fileURLWithPath: NSTemporaryDirectory()), displayName: "Temporary files")
        ]
        if let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            roots.append(ScanRoot(url: trash, displayName: "Trash"))
        }
        // Installer disk images / packages left behind in Downloads after you
        // dragged the app to Applications. Top level only and extension-filtered
        // on purpose — Downloads is full of files you actually want to keep.
        roots.append(ScanRoot(
            url: home.appendingPathComponent("Downloads"),
            displayName: "Installers in Downloads",
            recursive: false,
            extensions: ["dmg", "pkg", "mpkg", "iso"],
            groupBySubfolder: false
        ))
        return roots
    }

    func scan(completion: @escaping (ScanResult) -> Void) {
        let roots = scanRoots
        let ageLimit = minimumAgeDays

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let cutoff = Calendar.current.date(byAdding: .day, value: -ageLimit, to: Date()) ?? Date()

            // Keyed by the folder each file belongs to, so the review UI can
            // show "this much junk from Chrome" rather than 40,000 loose paths.
            var buckets: [URL: (category: String, name: String, files: [JunkFile])] = [:]

            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

            for root in roots {
                // Gather candidate URLs: either a deep walk or just the top level.
                var candidates: [URL] = []
                if root.recursive {
                    if let enumerator = fm.enumerator(
                        at: root.url,
                        includingPropertiesForKeys: keys,
                        options: [.skipsPackageDescendants]
                    ) {
                        for case let fileURL as URL in enumerator {
                            candidates.append(fileURL)
                        }
                    }
                } else {
                    candidates = (try? fm.contentsOfDirectory(
                        at: root.url,
                        includingPropertiesForKeys: keys,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                }

                for fileURL in candidates {
                    if let allowed = root.extensions,
                       !allowed.contains(fileURL.pathExtension.lowercased()) {
                        continue
                    }
                    guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                    guard values.isRegularFile == true else { continue }
                    guard let modified = values.contentModificationDate, modified < cutoff else { continue }

                    let size = Int64(values.fileSize ?? 0)
                    let file = JunkFile(url: fileURL, size: size, modified: modified)

                    // Group by the first folder under the root (usually the app's
                    // bundle id), falling back to the root itself for loose files.
                    let rootComponents = root.url.standardizedFileURL.pathComponents
                    let fileComponents = fileURL.standardizedFileURL.pathComponents
                    let containerURL: URL
                    let name: String
                    if root.groupBySubfolder, fileComponents.count > rootComponents.count + 1 {
                        let folderName = fileComponents[rootComponents.count]
                        containerURL = root.url.appendingPathComponent(folderName)
                        name = folderName
                    } else {
                        containerURL = root.url
                        name = root.displayName
                    }

                    buckets[containerURL, default: (root.displayName, name, [])].files.append(file)
                }
            }

            let groups = buckets
                .map { JunkGroup(
                    category: $0.value.category,
                    name: $0.value.name,
                    containerURL: $0.key,
                    files: $0.value.files
                ) }
                .sorted { $0.totalSize > $1.totalSize }

            DispatchQueue.main.async {
                completion(ScanResult(groups: groups))
            }
        }
    }

    /// Deletes the given files. Returns (deletedCount, freedBytes, errors).
    /// Continues past individual failures (e.g. a file in use) rather than
    /// aborting the whole batch.
    @discardableResult
    func delete(_ files: [JunkFile]) -> (deleted: Int, freed: Int64, errors: [Error]) {
        let fm = FileManager.default
        var deleted = 0
        var freed: Int64 = 0
        var errors: [Error] = []

        for file in files {
            do {
                try fm.removeItem(at: file.url)
                deleted += 1
                freed += file.size
            } catch {
                errors.append(error)
            }
        }
        return (deleted, freed, errors)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
