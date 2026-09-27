import Foundation

/// Names shown on the screenshots that are user data, not strings of the app (a disk name, a Bluetooth device):
/// the app does not translate them, so `titles.json` carries them for each language.
struct DemoNames: Decodable {
    var gpu: String
    var keyboard: String
    var mouse: String
    var earbuds: String
    var system: String
    var photos: String
    var backup: String
    var archive: String
}

/// Believable, varied numbers: a busy but not saturated CPU, medium memory pressure, an active network, a startup
/// disk two thirds full and a backup disk nearly full. Everything is fixed so every language gets the same picture.
@MainActor
struct DemoData {
    let names: DemoNames

    /// Monday 28 September 2026, 9:41, in the Mac's time zone.
    static let date: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 28
        components.hour = 9
        components.minute = 41
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_790_588_460)
    }()

    static let gib = 1_073_741_824.0
    static let gb = 1_000_000_000.0

    let cpu = CPUSample(user: 0.24, system: 0.12, idle: 0.64, perCore: [0.72, 0.61, 0.47, 0.38, 0.26, 0.19, 0.12, 0.08])
    let memory = MemorySample(total: 16 * gib, app: 5.2 * gib, wired: 3.2 * gib, compressed: 4.0 * gib)
    let network = NetworkSample(upload: 1_240_000, download: 18_600_000)
    let disk = DiskSample(name: "", total: 494.38 * gb, free: 142.71 * gb)
    let gpuUtilization = 0.37
    let localIP = "192.168.1.24"

    var gpus: [GPUSample] { [GPUSample(model: names.gpu, utilization: gpuUtilization)] }

    var bluetoothDevices: [BluetoothDevice] {
        [
            BluetoothDevice(name: names.keyboard, levels: [.init(part: .main, percent: 78)]),
            BluetoothDevice(name: names.mouse, levels: [.init(part: .main, percent: 16)]),
            // Earbuds report each side and the case, which shows how the popup lays out several levels.
            BluetoothDevice(name: names.earbuds, levels: [
                .init(part: .left, percent: 90), .init(part: .right, percent: 85), .init(part: .caseBattery, percent: 62),
            ]),
        ]
    }

    var volumes: [VolumeSample] {
        [
            VolumeSample(id: "/", name: names.system, isInternal: true, total: disk.total, free: disk.free, purgeable: 8.4 * Self.gb),
            VolumeSample(id: "/Volumes/Backup", name: names.backup, isInternal: false, total: 2_000.4 * Self.gb,
                         free: 131.6 * Self.gb, purgeable: nil),
            VolumeSample(id: "/Volumes/Photos", name: names.photos, isInternal: false, total: 1_000.2 * Self.gb,
                         free: 612.3 * Self.gb, purgeable: nil),
            VolumeSample(id: "/Volumes/Archive", name: names.archive, isInternal: false, total: 256.0 * Self.gb,
                         free: 201.9 * Self.gb, purgeable: 0.6 * Self.gb),
        ]
    }

    // MARK: - Histories (50 points, oldest first)

    /// Deterministic noise so the charts look measured, not drawn.
    static func noise(count: Int, seed: UInt64) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
    }

    static var cpuHistory: [Double] {
        let noise = noise(count: 50, seed: 7)
        return (0..<50).map { index in
            let base = 0.2 + 0.06 * sin(Double(index) / 3.5)
            let burst = index >= 31 && index <= 38 ? 0.38 * sin(Double(index - 30) / 9 * .pi) : 0
            return min(0.95, base + burst + 0.08 * noise[index])
        }.replacingLast(with: 0.36)
    }

    static var gpuHistory: [Double] {
        let noise = noise(count: 50, seed: 11)
        return (0..<50).map { index in
            let wave = 0.3 + 0.12 * sin(Double(index) / 5)
            return min(0.9, wave + 0.1 * noise[index])
        }.replacingLast(with: 0.37)
    }

    static var downloadHistory: [Double] {
        let noise = noise(count: 50, seed: 3)
        return (0..<50).map { index in
            let active = index >= 36 ? 16_000_000.0 + 5_000_000 * noise[index] : 400_000 + 2_600_000 * noise[index] * noise[index]
            return index == 20 || index == 21 ? 9_500_000 + 1_000_000 * noise[index] : active
        }.replacingLast(with: 18_600_000)
    }

    static var uploadHistory: [Double] {
        let noise = noise(count: 50, seed: 5)
        return (0..<50).map { index in
            index >= 38 ? 900_000 + 500_000 * noise[index] : 60_000 + 260_000 * noise[index] * noise[index]
        }.replacingLast(with: 1_240_000)
    }

    /// Change of used space between two disk samples, in bytes: small writes, one download, one cleanup.
    static var diskChanges: [Double] {
        let noise = noise(count: 50, seed: 13)
        return (0..<50).map { index in
            switch index {
            case 17: 1_850_000_000
            case 18: 620_000_000
            case 33: -940_000_000
            default: (noise[index] - 0.35) * 160_000_000
            }
        }
    }

    // MARK: - Applying

    func apply(to monitor: SystemMonitor) {
        monitor.cpu = cpu
        monitor.cpuHistory = History(capacity: SystemMonitor.historyLength, values: Self.cpuHistory)
        monitor.memory = memory
        monitor.disk = disk
        monitor.diskChanges = History(capacity: SystemMonitor.historyLength, values: Self.diskChanges)
        monitor.diskFlashing = false
        monitor.network = network
        monitor.uploadHistory = History(capacity: SystemMonitor.historyLength, values: Self.uploadHistory)
        monitor.downloadHistory = History(capacity: SystemMonitor.historyLength, values: Self.downloadHistory)
        monitor.localIP = localIP
        monitor.gpus = gpus
        monitor.gpuHistory = History(capacity: SystemMonitor.historyLength, values: Self.gpuHistory)
        monitor.bluetoothDevices = bluetoothDevices
        monitor.bluetoothLoaded = true
    }

    /// True while nothing measured on this Mac has replaced the demo numbers (a popup samples when it appears).
    func isShown(by monitor: SystemMonitor) -> Bool {
        monitor.cpu == cpu && monitor.memory == memory && monitor.disk == disk && monitor.network == network
            && monitor.gpus == gpus && monitor.bluetoothDevices == bluetoothDevices && monitor.localIP == localIP
            && monitor.cpuHistory.values == Self.cpuHistory && monitor.bluetoothLoaded
    }

    /// What the widgets receive, built by the app's own `widgetPayload`.
    func payload(from monitor: SystemMonitor) -> WidgetPayload {
        var payload = monitor.widgetPayload(now: Self.date)
        payload.volumes = volumes
        return payload
    }
}

private extension Array where Element == Double {
    /// The latest point equals the value shown in the headline, as in the app.
    func replacingLast(with value: Double) -> [Double] { dropLast() + [value] }
}
