// `kern.boottime` and `vm.swapusage` are read with sysctl.
@preconcurrency import Darwin
import Foundation

/// Every reading of the Mac at one moment, rounded and ready for the diagnostic: the rules judge it, the on-device
/// model rewrites what the rules found. Rounded on purpose: fewer tokens for the model, and the numbers it may cite
/// are the ones a person reads.
nonisolated struct MacSnapshot: Codable, Equatable, Sendable {
    struct Disk: Codable, Equatable, Sendable {
        /// Typed by the user: never trusted as an instruction.
        var name: String
        var isStartup: Bool
        var freeGB: Double
        var totalGB: Double
        var freePercent: Int
    }

    struct Device: Codable, Equatable, Sendable {
        /// Typed by the user: never trusted as an instruction.
        var name: String
        /// Lowest level of the device, nil when it does not report one.
        var battery: Int?
    }

    struct Battery: Codable, Equatable, Sendable {
        var charge: Int
        var isCharging: Bool
        var maximumCapacity: Int?
        var cycleCount: Int?
        var serviceRecommended: Bool
    }

    var date: Date
    /// Processor load, whole percent.
    var cpu: Int?
    /// Memory in use (apps, wired, compressed) over physical memory, whole percent.
    var memoryUsed: Int?
    /// Wired and compressed memory over physical memory, whole percent: memory macOS cannot hand back quickly.
    var memoryPressure: Int?
    var memoryTotalGB: Int?
    var swapGB: Double?
    var disks: [Disk]
    var downloadMBps: Double?
    var uploadMBps: Double?
    /// Busiest graphics processor, whole percent.
    var gpu: Int?
    var devices: [Device]
    var thermal: ThermalLevel?
    /// Nil on a Mac without a battery.
    var battery: Battery?
    /// Hours since the Mac started.
    var uptimeHours: Int?
    var keepAwake: Bool

    var startupDisk: Disk? { disks.first(where: \.isStartup) }
}

// MARK: - Building

extension MacSnapshot {
    /// Rounds the raw readings. Disk and device names are cleaned (`label`) when written for the model, not here.
    static func make(cpu: CPUSample?, memory: MemorySample?, swapUsed: Double?, volumes: [VolumeSample],
                     network: NetworkSample?, gpus: [GPUSample], devices: [BluetoothDevice], health: HealthSample?,
                     bootDate: Date?, keepAwake: Bool, now: Date) -> MacSnapshot {
        let disks = volumes
            .filter { $0.total > 0 }
            .sorted { ($0.id == "/" ? 0 : 1, $0.name) < ($1.id == "/" ? 0 : 1, $1.name) }
            .map {
                Disk(name: $0.name, isStartup: $0.id == "/", freeGB: gigabytes($0.free, unit: Format.decimalGigabyte),
                     totalGB: gigabytes($0.total, unit: Format.decimalGigabyte),
                     freePercent: percent($0.free / $0.total))
            }
        let battery = health?.battery.map {
            Battery(charge: $0.charge, isCharging: $0.isCharging, maximumCapacity: $0.maximumCapacity,
                    cycleCount: $0.cycleCount, serviceRecommended: $0.condition == .serviceRecommended)
        }
        return MacSnapshot(
            date: now,
            cpu: cpu.map { percent($0.total) },
            memoryUsed: memory.map { percent($0.usage) },
            memoryPressure: memory.map { percent($0.pressure) },
            memoryTotalGB: memory.map { Int(($0.total / Format.binaryGigabyte).rounded()) },
            swapGB: swapUsed.map { gigabytes($0, unit: Format.binaryGigabyte) },
            disks: disks,
            downloadMBps: network.map { megabytes($0.download) },
            uploadMBps: network.map { megabytes($0.upload) },
            gpu: gpus.map(\.utilization).max().map(percent),
            devices: devices.map { Device(name: $0.name, battery: $0.lowest) },
            thermal: health?.thermal,
            battery: battery,
            uptimeHours: bootDate.map { max(0, Int(now.timeIntervalSince($0) / 3_600)) },
            keepAwake: keepAwake
        )
    }

    static func percent(_ fraction: Double) -> Int { Int((Format.clamp(fraction) * 100).rounded()) }

    /// Whole gigabytes from 10 up, one decimal under.
    static func gigabytes(_ bytes: Double, unit: Double) -> Double {
        let value = max(0, bytes.isFinite ? bytes : 0) / unit
        return value >= 10 ? value.rounded() : (value * 10).rounded() / 10
    }

    /// Whole megabytes per second from 10 up, one decimal under.
    static func megabytes(_ bytesPerSecond: Double) -> Double {
        let value = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0) / 1_000_000
        return value >= 10 ? value.rounded() : (value * 10).rounded() / 10
    }
}

// MARK: - Text for the model

/// The topics of the snapshot, one read-only tool each in the conversation.
nonisolated enum SnapshotDomain: String, CaseIterable, Sendable {
    case cpu, memory, disks, network, gpu, bluetooth, health, keepAwake
}

extension MacSnapshot {
    /// Longest name kept for the model: enough to tell devices apart, too short to carry a long instruction.
    static let labelLength = 40

    /// A name typed by the user, written between ⟦ and ⟧. Control characters, line breaks and the two brackets are
    /// removed, so a name can neither close its brackets nor start a new line that looks like a fact.
    static func label(_ name: String) -> String {
        let cleaned = name.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .replacingOccurrences(of: "⟦", with: "")
            .replacingOccurrences(of: "⟧", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let short = cleaned.count > labelLength ? String(cleaned.prefix(labelLength)) + "…" : cleaned
        return "⟦\(short.isEmpty ? "unnamed" : short)⟧"
    }

    /// Plain number, dot decimal, no grouping: the form the model copies and the validation reads back.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// The lines of one topic, in English: the model writes in the user's language from them.
    func facts(_ domain: SnapshotDomain) -> [String] {
        switch domain {
        case .cpu:
            return [cpu.map { "processor: \($0)% busy" } ?? "processor: not measured"]
        case .memory:
            guard let memoryUsed else { return ["memory: not measured"] }
            var line = "memory: \(memoryUsed)% used"
            if let memoryTotalGB { line += " of \(memoryTotalGB) GB" }
            if let memoryPressure { line += ", wired and compressed \(memoryPressure)%" }
            if let swapGB { line += ", swap \(Self.number(swapGB)) GB" }
            return [line]
        case .disks:
            guard !disks.isEmpty else { return ["disks: not measured"] }
            return disks.map {
                "disk \(Self.label($0.name))\($0.isStartup ? " (startup disk)" : ""): \(Self.number($0.freeGB)) GB free "
                    + "of \(Self.number($0.totalGB)) GB, \($0.freePercent)% free"
            }
        case .network:
            guard let downloadMBps, let uploadMBps else { return ["network: not measured"] }
            return ["network: receiving \(Self.number(downloadMBps)) MB/s, sending \(Self.number(uploadMBps)) MB/s"]
        case .gpu:
            return [gpu.map { "graphics: \($0)% busy" } ?? "graphics: not measured"]
        case .bluetooth:
            guard !devices.isEmpty else { return ["bluetooth: no device connected"] }
            return devices.map {
                "bluetooth \(Self.label($0.name)): " + ($0.battery.map { "battery \($0)%" } ?? "battery not reported")
            }
        case .health:
            var lines = ["heat: \(thermal.map(\.factName) ?? "not measured")"]
            if let battery {
                var line = "mac battery: \(battery.charge)%, \(battery.isCharging ? "charging" : "not charging")"
                if let capacity = battery.maximumCapacity { line += ", maximum capacity \(capacity)%" }
                if let cycles = battery.cycleCount { line += ", \(cycles) cycles" }
                if battery.serviceRecommended { line += ", service recommended" }
                lines.append(line)
            } else {
                lines.append("mac battery: none (desktop Mac)")
            }
            if let uptimeHours {
                lines.append(uptimeHours >= 48 ? "running for \(uptimeHours / 24) days" : "running for \(uptimeHours) hours")
            }
            return lines
        case .keepAwake:
            return ["keep awake: \(keepAwake ? "on" : "off")"]
        }
    }

    /// Every topic, one fact per line.
    var facts: String {
        SnapshotDomain.allCases.flatMap(facts).joined(separator: "\n")
    }
}

extension ThermalLevel {
    /// English word for the model; the user reads `title`.
    var factName: String {
        switch self {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "hot, macOS slows the Mac down"
        case .critical: "critical"
        }
    }
}

// MARK: - Changes

extension MacSnapshot {
    /// A change a person would notice in the diagnostic. Under it, a recent diagnostic is still right.
    func differsNotably(from other: MacSnapshot) -> Bool {
        func moved(_ a: Int?, _ b: Int?, by limit: Int) -> Bool {
            switch (a, b) {
            case let (a?, b?): abs(a - b) >= limit
            case (nil, nil): false
            default: true
            }
        }
        func moved(_ a: Double?, _ b: Double?, by limit: Double) -> Bool {
            switch (a, b) {
            case let (a?, b?): abs(a - b) >= limit
            case (nil, nil): false
            default: true
            }
        }
        if moved(cpu, other.cpu, by: 15) || moved(memoryUsed, other.memoryUsed, by: 10)
            || moved(swapGB, other.swapGB, by: 1) || moved(gpu, other.gpu, by: 20)
            || moved(downloadMBps, other.downloadMBps, by: 5) || moved(uploadMBps, other.uploadMBps, by: 5) {
            return true
        }
        if thermal != other.thermal || keepAwake != other.keepAwake { return true }
        if disks.map(\.name) != other.disks.map(\.name)
            || zip(disks, other.disks).contains(where: { abs($0.freePercent - $1.freePercent) >= 2 }) {
            return true
        }
        if devices.map(\.name) != other.devices.map(\.name)
            || zip(devices, other.devices).contains(where: { moved($0.battery, $1.battery, by: 5) }) {
            return true
        }
        switch (battery, other.battery) {
        case let (a?, b?): return abs(a.charge - b.charge) >= 5 || a.isCharging != b.isCharging
        case (nil, nil): return false
        default: return true
        }
    }
}

// MARK: - Reading

nonisolated enum MacSnapshotReader {
    /// Processor and network speeds are measured between two readings this far apart.
    static let measuringTime: Duration = .seconds(1)

    /// Reads every module once, away from the main actor. Takes about a second: the processor and the network
    /// are measured between two readings.
    @concurrent static func take(keepAwake: Bool) async -> MacSnapshot {
        let cpuReader = CPUReader()
        let networkReader = NetworkReader()
        _ = cpuReader.read()
        _ = networkReader.read()
        async let devices = BluetoothReader.read()
        try? await Task.sleep(for: measuringTime)
        let cpu = cpuReader.read()
        let network = networkReader.read()?.sample
        return MacSnapshot.make(
            cpu: cpu, memory: MemoryReader.read(), swapUsed: MemoryReader.swapUsed(), volumes: VolumeReader.read(),
            network: network, gpus: GPUReader.read(), devices: await devices, health: HealthReader.read(battery: true),
            bootDate: bootDate(), keepAwake: keepAwake, now: .now
        )
    }

    /// When the Mac started (`sysctl kern.boottime`), sleep included.
    static func bootDate() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}

/// The readings the diagnostic and the conversation share: a snapshot stays fresh a few seconds, so a question that
/// calls three tools measures the Mac once.
actor SnapshotSource {
    static let freshness: TimeInterval = 10

    private let keepAwake: @MainActor @Sendable () -> Bool
    private var last: MacSnapshot?
    private var reading: Task<MacSnapshot, Never>?

    init(keepAwake: @escaping @MainActor @Sendable () -> Bool) {
        self.keepAwake = keepAwake
    }

    /// The last snapshot while it is fresh, a new one otherwise; `fresh` always measures again.
    func current(fresh: Bool = false) async -> MacSnapshot {
        if !fresh, let last, Date.now.timeIntervalSince(last.date) < Self.freshness { return last }
        if let reading { return await reading.value }
        let keepAwake = keepAwake
        let task = Task { await MacSnapshotReader.take(keepAwake: await keepAwake()) }
        reading = task
        let snapshot = await task.value
        last = snapshot
        reading = nil
        return snapshot
    }
}
