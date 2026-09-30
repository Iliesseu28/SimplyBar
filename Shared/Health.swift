import Foundation

/// How hot the Mac runs, as macOS tells apps (`ProcessInfo.thermalState`). macOS gives no temperature in degrees
/// to a sandboxed app: the sensors sit behind the SMC, closed to the App Sandbox.
nonisolated enum ThermalLevel: String, CaseIterable, Codable, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        // A level added later: no false alarm.
        @unknown default: self = .nominal
        }
    }

    /// Hot enough for macOS to slow the Mac down: worth telling the user.
    var isHot: Bool { self == .serious || self == .critical }

    var title: LocalizedStringResource {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        }
    }

    /// What to do about it, only when the Mac is hot.
    var advice: LocalizedStringResource? {
        switch self {
        case .nominal, .fair: nil
        case .serious: "Hot: macOS slows the Mac down to cool it. Quit heavy apps and keep the vents clear."
        case .critical: "Very hot: save your work, quit heavy apps and let the Mac cool down."
        }
    }
}

/// The Mac's own battery, on a laptop. A value macOS does not give stays nil and its row is left out.
nonisolated struct MacBattery: Codable, Equatable, Sendable {
    enum Condition: String, Codable, Sendable {
        case normal, serviceRecommended
    }

    /// Charge, whole percent between 0 and 100.
    var charge: Int
    var isCharging: Bool
    /// Full-charge capacity over the capacity it had new, whole percent, at most 100.
    var maximumCapacity: Int?
    var cycleCount: Int?
    var condition: Condition?
}

/// What the Health module shows: the heat level, and the battery on a Mac that has one.
nonisolated struct HealthSample: Codable, Equatable, Sendable {
    var thermal: ThermalLevel
    /// Nil on a Mac without a battery (desktop Macs).
    var battery: MacBattery?
}
