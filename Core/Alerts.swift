import Foundation

/// What SimplyBar can warn about with a notification. Every alert is off until the user turns it on.
nonisolated enum AlertKind: String, CaseIterable, Codable, Sendable {
    case bluetoothBattery, diskSpace, heat
}

/// The alerts turned on in the settings.
nonisolated struct AlertSettings: Codable, Equatable, Sendable {
    var bluetoothBattery = false
    var diskSpace = false
    var heat = false

    init() {}

    /// A value missing from the saved JSON keeps its default (off).
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let on = try? values.decodeIfPresent(Bool.self, forKey: .bluetoothBattery) { bluetoothBattery = on }
        if let on = try? values.decodeIfPresent(Bool.self, forKey: .diskSpace) { diskSpace = on }
        if let on = try? values.decodeIfPresent(Bool.self, forKey: .heat) { heat = on }
    }

    func isOn(_ kind: AlertKind) -> Bool {
        switch kind {
        case .bluetoothBattery: bluetoothBattery
        case .diskSpace: diskSpace
        case .heat: heat
        }
    }

    mutating func set(_ kind: AlertKind, _ on: Bool) {
        switch kind {
        case .bluetoothBattery: bluetoothBattery = on
        case .diskSpace: diskSpace = on
        case .heat: heat = on
        }
    }
}

/// One notification to send.
nonisolated enum Alert: Equatable, Sendable {
    case bluetoothBattery(device: String, percent: Int)
    /// Bytes.
    case diskSpace(free: Double, total: Double)
    case heat(ThermalLevel)

    var kind: AlertKind {
        switch self {
        case .bluetoothBattery: .bluetoothBattery
        case .diskSpace: .diskSpace
        case .heat: .heat
        }
    }
}

/// Where a reading stands. Between the alarm threshold and the normal one nothing changes: a value hovering around
/// a threshold neither fires again nor re-arms the alert.
nonisolated enum AlertLevel: Equatable, Sendable {
    case normal, near, alarm
}

/// Thresholds, each with a margin before the alert counts as over.
nonisolated enum AlertRules {
    /// A Bluetooth device at this percent or under is low (the level the app draws in red), normal again from
    /// `bluetoothRecovered`.
    static let bluetoothLow = 20
    static let bluetoothRecovered = 25
    /// The startup disk is almost full under this free share, normal again from `diskRecovered`.
    static let diskLow = 0.10
    static let diskRecovered = 0.12

    static func bluetooth(_ percent: Int) -> AlertLevel {
        percent <= bluetoothLow ? .alarm : percent >= bluetoothRecovered ? .normal : .near
    }

    static func disk(free: Double, total: Double) -> AlertLevel {
        guard total > 0 else { return .normal }
        let share = free / total
        return share < diskLow ? .alarm : share >= diskRecovered ? .normal : .near
    }

    /// Hot or critical fires; normal or warm is over.
    static func heat(_ level: ThermalLevel) -> AlertLevel {
        level.isHot ? .alarm : .normal
    }
}

/// Keeps the alerts quiet: an alert fires when its object enters the alarm, then waits for the object to be back to
/// normal before it can fire again, and never fires twice within `minimumGap` for the same object. Saved by the app
/// so that a relaunch does not repeat an alert.
nonisolated struct AlertTracker: Codable, Equatable, Sendable {
    static let minimumGap: TimeInterval = 60 * 60

    /// Objects that fired and are not back to normal yet.
    private(set) var waiting: Set<String> = []
    private(set) var lastFired: [String: Date] = [:]

    init() {}

    /// Feeds one reading of an object; true when its notification goes out now. An alarm held back by the gap fires
    /// on a later reading once the hour has passed, if the object is still in alarm.
    mutating func update(_ key: String, _ level: AlertLevel, now: Date) -> Bool {
        switch level {
        case .normal:
            waiting.remove(key)
            return false
        case .near:
            return false
        case .alarm:
            guard !waiting.contains(key) else { return false }
            if let last = lastFired[key], now.timeIntervalSince(last) < Self.minimumGap { return false }
            waiting.insert(key)
            lastFired[key] = now
            return true
        }
    }

    /// One alert per connected device at or under the low level (its lowest part: left, right or case). A device
    /// that disconnects keeps its state until it comes back.
    mutating func bluetooth(_ devices: [BluetoothDevice], now: Date) -> [Alert] {
        devices.compactMap { device in
            guard let lowest = device.lowest,
                  update(Self.key(.bluetoothBattery, device.id), AlertRules.bluetooth(lowest), now: now) else { return nil }
            return .bluetoothBattery(device: device.name, percent: lowest)
        }
    }

    mutating func disk(_ sample: DiskSample, now: Date) -> [Alert] {
        let level = AlertRules.disk(free: sample.free, total: sample.total)
        return update(Self.key(.diskSpace, "/"), level, now: now) ? [.diskSpace(free: sample.free, total: sample.total)] : []
    }

    mutating func heat(_ level: ThermalLevel, now: Date) -> [Alert] {
        update(Self.key(.heat, "mac"), AlertRules.heat(level), now: now) ? [.heat(level)] : []
    }

    /// An alert turned off starts afresh when turned on again; the hour between two notifications still holds.
    mutating func reset(_ kind: AlertKind) {
        let prefix = kind.rawValue + ":"
        waiting = waiting.filter { !$0.hasPrefix(prefix) }
    }

    static func key(_ kind: AlertKind, _ object: String) -> String { "\(kind.rawValue):\(object)" }
}
