import Foundation
import Observation
import SwiftUI

/// The modules, in the order of the settings sidebar.
enum Module: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, gpu, network, disk, bluetooth

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "SSD"
        case .bluetooth: "Bluetooth"
        }
    }

    /// Short letters stacked in the menu bar label.
    var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .gpu: "GPU"
        case .network: "NET"
        case .disk: "SSD"
        case .bluetooth: "BT"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.3.layers.3d"
        case .network: "network"
        case .disk: "internaldrive"
        case .bluetooth: "dot.radiowaves.left.and.right"
        }
    }
}

enum CPUMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case total, system, user, idle, userSystem, perCore
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .total: "Total Usage"
        case .system: "System"
        case .user: "User"
        case .idle: "Idle"
        case .userSystem: "User + System"
        case .perCore: "Usage Per Core"
        }
    }
}

enum MemoryMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case total, app, wired, compressed, pressure
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .total: "Total Usage"
        case .app: "Apps"
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .pressure: "Pressure"
        }
    }
}

enum NetworkMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case upload, download, both, ipAddress
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .upload: "Upload"
        case .download: "Download"
        case .both: "Upload + Download"
        case .ipAddress: "IP Address"
        }
    }
}

enum DiskMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case total, free, used
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .total: "Total"
        case .free: "Free"
        case .used: "Used"
        }
    }
}

/// How a value is drawn in the menu bar.
enum ValueStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case bar, percent, gigabytes
    var id: String { rawValue }
    /// "%" stays verbatim: a lone percent sign must not go through string formatting.
    var label: Text {
        switch self {
        case .bar: Text("Bar")
        case .percent: Text(verbatim: "%")
        case .gigabytes: Text("GB")
        }
    }
}

struct CPUSettings: Codable, Equatable, Sendable {
    var shown = true
    var interval = 3
    var showIcon = true
    var showLabel = true
    /// Two bars side by side, user then system: the default look of the CPU item.
    var metric = CPUMetric.userSystem
    var style = ValueStyle.bar
}

struct MemorySettings: Codable, Equatable, Sendable {
    var shown = true
    var showIcon = true
    var showLabel = true
    var metric = MemoryMetric.total
    var style = ValueStyle.bar
}

struct GPUSettings: Codable, Equatable, Sendable {
    var shown = true
    var interval = 3
    var showIcon = true
    var showLabel = true
    var style = ValueStyle.bar
}

/// Versions before 1.0 also saved `showPublicIP`: decoding ignores that extra key, the other values are kept.
struct NetworkSettings: Codable, Equatable, Sendable {
    var shown = true
    var showIcon = true
    var showLabel = true
    var metric = NetworkMetric.both
}

struct DiskSettings: Codable, Equatable, Sendable {
    var shown = true
    var showIcon = true
    var showLabel = false
    var flashOnChange = false
    var metric = DiskMetric.free
    var style = ValueStyle.gigabytes
}

struct BluetoothSettings: Codable, Equatable, Sendable {
    var shown = false
    var showIcon = true
    var showLabel = false
    var interval = Sampling.defaultBluetoothInterval
}

/// User settings, saved in the app's own UserDefaults (one JSON value per module).
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    /// Called after any change that affects sampling (visibility, interval).
    @ObservationIgnored var onChange: (() -> Void)?

    var cpu: CPUSettings { didSet { save(cpu, key: "cpu") } }
    var memory: MemorySettings { didSet { save(memory, key: "memory") } }
    var gpu: GPUSettings { didSet { save(gpu, key: "gpu") } }
    var network: NetworkSettings { didSet { save(network, key: "network") } }
    var disk: DiskSettings { didSet { save(disk, key: "disk") } }
    var bluetooth: BluetoothSettings { didSet { save(bluetooth, key: "bluetooth") } }
    var openSettingsAtLaunch: Bool { didSet { defaults.set(openSettingsAtLaunch, forKey: "openSettingsAtLaunch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A saved interval outside the offered list (edited by hand, or 0) would sample in a tight loop.
        var cpu = Self.load(CPUSettings.self, key: "cpu", from: defaults) ?? CPUSettings()
        cpu.interval = Sampling.closest(to: cpu.interval, in: Sampling.intervals)
        self.cpu = cpu
        memory = Self.load(MemorySettings.self, key: "memory", from: defaults) ?? MemorySettings()
        var gpu = Self.load(GPUSettings.self, key: "gpu", from: defaults) ?? GPUSettings()
        gpu.interval = Sampling.closest(to: gpu.interval, in: Sampling.intervals)
        self.gpu = gpu
        network = Self.load(NetworkSettings.self, key: "network", from: defaults) ?? NetworkSettings()
        disk = Self.load(DiskSettings.self, key: "disk", from: defaults) ?? DiskSettings()
        var bluetooth = Self.load(BluetoothSettings.self, key: "bluetooth", from: defaults) ?? BluetoothSettings()
        // Older versions offered 2 to 59 seconds for Bluetooth too.
        bluetooth.interval = Sampling.closest(to: bluetooth.interval, in: Sampling.bluetoothIntervals)
        self.bluetooth = bluetooth
        openSettingsAtLaunch = defaults.object(forKey: "openSettingsAtLaunch") as? Bool ?? true
    }

    func isShown(_ module: Module) -> Bool {
        switch module {
        case .cpu: cpu.shown
        case .memory: memory.shown
        case .gpu: gpu.shown
        case .network: network.shown
        case .disk: disk.shown
        case .bluetooth: bluetooth.shown
        }
    }

    func setShown(_ module: Module, _ shown: Bool) {
        switch module {
        case .cpu: cpu.shown = shown
        case .memory: memory.shown = shown
        case .gpu: gpu.shown = shown
        case .network: network.shown = shown
        case .disk: disk.shown = shown
        case .bluetooth: bluetooth.shown = shown
        }
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "settings.\(key)") }
        onChange?()
    }

    private static func load<Value: Decodable>(_ type: Value.Type, key: String, from defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: "settings.\(key)") else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
