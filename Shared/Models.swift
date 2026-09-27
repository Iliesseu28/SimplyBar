import Foundation

/// One CPU measurement. Every value is a fraction between 0 and 1.
nonisolated struct CPUSample: Codable, Equatable, Sendable {
    var user: Double
    var system: Double
    var idle: Double
    var perCore: [Double]

    /// Share of time spent working (user + system), the "Total Usage" of the popup.
    var total: Double { min(1, max(0, user + system)) }
}

/// Memory split the way Activity Monitor counts it. Values are bytes.
nonisolated struct MemorySample: Codable, Equatable, Sendable {
    var total: Double
    var app: Double
    var wired: Double
    var compressed: Double

    var used: Double { app + wired + compressed }
    var free: Double { max(0, total - used) }
    var usage: Double { total > 0 ? min(1, used / total) : 0 }

    /// Memory the system cannot hand back quickly (wired + compressed) over physical memory.
    var pressure: Double { total > 0 ? min(1, (wired + compressed) / total) : 0 }
}

/// Space of the startup volume. Values are bytes.
nonisolated struct DiskSample: Codable, Equatable, Sendable {
    var name: String
    var total: Double
    /// Space available for important usage: free blocks plus what macOS can purge on demand (Finder's number).
    var free: Double

    var used: Double { max(0, total - free) }
    var usage: Double { total > 0 ? min(1, used / total) : 0 }
}

/// One disk of the Storage widget: the startup disk or an external drive, its APFS volumes counted once. Bytes.
nonisolated struct VolumeSample: Codable, Equatable, Sendable, Identifiable {
    /// Mount path of the disk's main volume ("/" for the startup disk): stable while the disk keeps its name.
    var id: String
    var name: String
    var isInternal: Bool
    var total: Double
    /// Free blocks plus purgeable space, Finder's "available" number.
    var free: Double
    /// Part of `free` macOS reclaims on demand (caches, local snapshots); nil when the system does not say.
    var purgeable: Double?

    var used: Double { max(0, total - free) }
    var usage: Double { total > 0 ? min(1, used / total) : 0 }
}

/// Throughput of the physical network interfaces, in bytes per second.
nonisolated struct NetworkSample: Codable, Equatable, Sendable {
    var upload: Double
    var download: Double
}

/// Utilization of one graphics processor, fraction between 0 and 1.
nonisolated struct GPUSample: Codable, Equatable, Sendable {
    var model: String
    var utilization: Double
}

/// A connected Bluetooth device, with its battery levels when macOS gives them.
nonisolated struct BluetoothDevice: Codable, Equatable, Sendable, Identifiable {
    enum Part: String, Codable, Sendable {
        case main, left, right, caseBattery
    }

    struct Level: Codable, Equatable, Sendable {
        var part: Part
        var percent: Int
    }

    /// Unique in a list of devices: two devices may share a name (see `BluetoothReader.merge`).
    var id: String
    var name: String
    /// Bluetooth address (`00:11:22:33:44:55`) when the source gives it.
    var address: String?
    /// Empty when the device does not report its battery.
    var levels: [Level]

    init(name: String, address: String? = nil, levels: [Level]) {
        id = address ?? name
        self.name = name
        self.address = address
        self.levels = levels
    }

    /// Lowest level, the one shown in the menu bar.
    var lowest: Int? { levels.map(\.percent).min() }
}

/// Fixed-size list of the most recent values, oldest first.
nonisolated struct History: Codable, Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int, values: [Double] = []) {
        self.capacity = max(1, capacity)
        self.values = Array(values.suffix(self.capacity))
    }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    func last(_ count: Int) -> [Double] { Array(values.suffix(count)) }
}
