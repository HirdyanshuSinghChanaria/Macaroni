import Foundation

/// Free/total space on the startup volume — the "storage left" readout.
enum DiskSpace {

    struct Capacity {
        let free: Int64
        let total: Int64

        var used: Int64 { max(0, total - free) }
        var usedFraction: Double {
            guard total > 0 else { return 0 }
            return Double(used) / Double(total)
        }
        var freeFraction: Double {
            guard total > 0 else { return 0 }
            return Double(free) / Double(total)
        }
    }

    static func current() -> Capacity? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]) else { return nil }

        // "ForImportantUsage" is what Finder reports as available — it counts
        // space macOS would purge for you, so it matches what the user sees.
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values.volumeTotalCapacity ?? 0)
        guard total > 0 else { return nil }
        return Capacity(free: free, total: total)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
