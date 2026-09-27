import Foundation

/// What the menu bar app hands to the widgets: only what a widget draws (see `SystemMonitor.widgetPayload`).
/// A file written by an older version may carry more keys (`gpu`): decoding ignores them.
nonisolated struct WidgetPayload: Codable, Equatable, Sendable {
    /// Number of history points a widget draws.
    static let historyLength = 20

    var date: Date
    var cpu: CPUSample?
    var cpuHistory: [Double] = []
    var memory: MemorySample?
    var network: NetworkSample?
    var uploadHistory: [Double] = []
    var downloadHistory: [Double] = []
    var disk: DiskSample?
    /// Every disk, written only while a Storage widget is on the desktop.
    var volumes: [VolumeSample]?
}

/// The App Group container shared by the app and its widget extension, both sandboxed.
///
/// The identifier starts with the team ID: on macOS the code signature alone authorises it, without a
/// provisioning profile and without the "access data from other apps" prompt. Mac App Store builds accept it too.
nonisolated enum SharedStore {
    static let appGroup = "ZNPYGQCK98.fr.simplibot.simplybar"

    /// Past this age a widget says the app is not running instead of showing old numbers as current. The app
    /// rewrites the numbers every 30 minutes, give or take a few minutes of timer slack.
    static let freshness: TimeInterval = 45 * 60

    /// A widget's kind is this prefix plus what it shows (`cpu`, `memory`, `network`, `disk`, `storage`), so the app
    /// can tell from the widgets on the desktop which numbers to keep up to date.
    static let widgetKindPrefix = "fr.simplibot.simplybar."
    static let storageWidgetKind = widgetKindPrefix + "storage"

    private static let fileName = "widget-payload.json"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func encode(_ payload: WidgetPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> WidgetPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetPayload.self, from: data)
    }

    static func save(_ payload: WidgetPayload) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(payload).write(to: url, options: .atomic)
    }

    static func load() -> WidgetPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    static func isFresh(_ payload: WidgetPayload, now: Date = .now) -> Bool {
        now.timeIntervalSince(payload.date) < freshness
    }
}
