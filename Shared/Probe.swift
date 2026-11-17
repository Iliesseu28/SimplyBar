import OSLog

/// Measurement lines in the unified log (category "probe"): what the app published, what each reading cost, which
/// popups were opened and when WidgetKit asked a widget to redraw. A script follows them over days (`tools/probe`)
/// to check the numbers against the system and find what to optimize. Numbers and SimplyBar's own names only:
/// never a disk or device name.
nonisolated enum Probe {
    static let log = Logger(subsystem: "fr.simplibot.simplybar", category: "probe")

    /// Widget kind without the common prefix ("cpu", "storage").
    static func shortKind(_ kind: String) -> String {
        kind.hasPrefix(SharedStore.widgetKindPrefix) ? String(kind.dropFirst(SharedStore.widgetKindPrefix.count)) : kind
    }

    /// When WidgetKit asks a widget for its timeline, and how old the numbers it gets are (-1: no file).
    static func timeline(kind: String, payload: WidgetPayload?, now: Date) {
        let age = payload.map { Int(now.timeIntervalSince($0.date)) } ?? -1
        let fresh = payload.map { SharedStore.isFresh($0, now: now) } ?? false
        log.notice("timeline kind=\(shortKind(kind), privacy: .public) age=\(age, privacy: .public) fresh=\(fresh, privacy: .public)")
    }
}
