import Foundation

/// How long the Mac stays awake once Keep Awake is turned on. The raw value is in seconds.
nonisolated enum KeepAwakeDuration: Int, CaseIterable, Identifiable, Codable, Sendable {
    case indefinitely = 0
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400

    var id: Int { rawValue }

    /// When a session started at `start` ends, nil when it lasts until turned off.
    func end(from start: Date) -> Date? {
        self == .indefinitely ? nil : start.addingTimeInterval(TimeInterval(rawValue))
    }

    var title: LocalizedStringResource {
        switch self {
        case .indefinitely: "Indefinitely"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .fourHours: "4 hours"
        }
    }
}

/// Keep Awake settings. Keep Awake itself is never saved on: after a relaunch the Mac is free to sleep again.
nonisolated struct KeepAwakeSettings: Codable, Equatable, Sendable {
    var shown = true
    var duration = KeepAwakeDuration.indefinitely
    var keepsDisplayOn = false

    init() {}

    /// A value missing from the saved JSON, or no longer offered (a duration removed later), keeps its default.
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let shown = try? values.decodeIfPresent(Bool.self, forKey: .shown) { self.shown = shown }
        if let duration = try? values.decodeIfPresent(KeepAwakeDuration.self, forKey: .duration) { self.duration = duration }
        if let keepsDisplayOn = try? values.decodeIfPresent(Bool.self, forKey: .keepsDisplayOn) {
            self.keepsDisplayOn = keepsDisplayOn
        }
    }
}

/// Keep Awake as the app last wrote it for the widget.
nonisolated struct KeepAwakeStatus: Codable, Equatable, Sendable {
    var isActive: Bool
    /// End of a timed session; nil while off, or when it lasts until turned off.
    var end: Date?
    var keepsDisplayOn: Bool

    /// A timed session past its end counts as off, even before the app says so.
    func isActive(at now: Date) -> Bool {
        isActive && (end.map { $0 > now } ?? true)
    }

    /// Seconds left at `now`, nil when off or untimed.
    func remaining(at now: Date) -> TimeInterval? {
        guard isActive(at: now), let end else { return nil }
        return end.timeIntervalSince(now)
    }
}

/// What a click on the Keep Awake widget asks for. The widget's intent runs in the extension, which quits right
/// after and so cannot hold a power assertion: it writes this request in the App Group, posts
/// `SharedStore.keepAwakeNotification`, and the app does the work.
nonisolated struct KeepAwakeRequest: Codable, Equatable, Sendable {
    var isActive: Bool
    var date: Date
}

/// What the Keep Awake widget shows.
nonisolated struct KeepAwakeWidgetState: Equatable, Sendable {
    /// A request the app has not answered is shown for this long; past it, the widget goes back to the app's word.
    static let pendingWindow: TimeInterval = 10

    var isActive: Bool
    /// End of a timed session, unknown while a request waits for the app.
    var end: Date?
    /// Asked from the widget, not yet confirmed by the app.
    var isPending: Bool
    /// When the app wrote the state.
    var date: Date

    /// Nil when the app is not running: no fresh file, or no Keep Awake in it (the app removes it when it quits).
    static func resolve(payload: WidgetPayload?, request: KeepAwakeRequest?, now: Date = .now) -> KeepAwakeWidgetState? {
        guard let payload, SharedStore.isFresh(payload, now: now), let status = payload.keepAwake else { return nil }
        if let request, request.date > payload.date, now.timeIntervalSince(request.date) < pendingWindow {
            return KeepAwakeWidgetState(isActive: request.isActive, end: nil, isPending: true, date: payload.date)
        }
        let active = status.isActive(at: now)
        return KeepAwakeWidgetState(isActive: active, end: active ? status.end : nil, isPending: false, date: payload.date)
    }
}
