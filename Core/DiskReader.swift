import Foundation

/// Space of the startup volume.
///
/// Free space is `volumeAvailableCapacityForImportantUsage`: free blocks plus the purgeable space macOS reclaims on
/// demand. Finder shows this number too; `df` counts free blocks only, so it shows less.
nonisolated enum DiskReader {
    /// Used-space change between two samples that makes the menu bar item flash (500 MB). The sandbox rounds free
    /// space down to 3 significant digits of blocks, a 409.6 MB step on a 245 GB disk: a smaller threshold would
    /// flash on rounding alone.
    static let significantChange = 500_000_000.0

    static func isSignificantChange(_ change: Double) -> Bool {
        abs(change) >= significantChange
    }

    static let keys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeLocalizedNameKey,
    ]

    static func read(path: String = "/") -> DiskSample? {
        // A fresh URL each time: URL instances cache their resource values.
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let free = important > 0 ? Double(important) : Double(values.volumeAvailableCapacity ?? 0)
        return DiskSample(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            total: Double(total),
            free: min(free, Double(total))
        )
    }

    /// Free blocks only, the "Avail" column of `df`. Used for the log line that compares both numbers.
    static func freeBlocks(path: String = "/") -> Double? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Double(info.f_bavail) * Double(info.f_bsize)
    }
}
