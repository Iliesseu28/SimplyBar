import Foundation

/// What the menu bar app hands to the widgets: only what a widget draws (see `SystemMonitor.widgetPayload`).
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
    /// The busiest graphics processor (nil when none can be read) and its history, written only while a GPU widget
    /// is on the desktop. An empty history means not measured yet.
    var gpu: GPUSample?
    var gpuHistory: [Double] = []
    /// Connected Bluetooth devices, written only while a Bluetooth widget is on the desktop; nil until the first
    /// reading.
    var bluetooth: [BluetoothDevice]?
    /// Keep Awake as it stands; nil when the app is not running (it removes it when it quits).
    var keepAwake: KeepAwakeStatus?
    /// Heat level and battery, written only while a Mac Health widget is on the desktop.
    var health: HealthSample?
}

extension WidgetPayload {
    /// Only the date is required. A key an older or newer version did not write, or wrote in another shape, leaves
    /// that value empty instead of failing the whole file.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(Date.self, forKey: .date)
        cpu = try? values.decodeIfPresent(CPUSample.self, forKey: .cpu)
        cpuHistory = (try? values.decodeIfPresent([Double].self, forKey: .cpuHistory)) ?? []
        memory = try? values.decodeIfPresent(MemorySample.self, forKey: .memory)
        network = try? values.decodeIfPresent(NetworkSample.self, forKey: .network)
        uploadHistory = (try? values.decodeIfPresent([Double].self, forKey: .uploadHistory)) ?? []
        downloadHistory = (try? values.decodeIfPresent([Double].self, forKey: .downloadHistory)) ?? []
        disk = try? values.decodeIfPresent(DiskSample.self, forKey: .disk)
        volumes = try? values.decodeIfPresent([VolumeSample].self, forKey: .volumes)
        gpu = try? values.decodeIfPresent(GPUSample.self, forKey: .gpu)
        gpuHistory = (try? values.decodeIfPresent([Double].self, forKey: .gpuHistory)) ?? []
        bluetooth = try? values.decodeIfPresent([BluetoothDevice].self, forKey: .bluetooth)
        keepAwake = try? values.decodeIfPresent(KeepAwakeStatus.self, forKey: .keepAwake)
        health = try? values.decodeIfPresent(HealthSample.self, forKey: .health)
    }
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

    /// A widget's kind is this prefix plus what it shows (`cpu`, `memory`, `gpu`, `network`, `disk`, `storage`,
    /// `bluetooth`, `keepAwake`, `health`), so the app can tell from the widgets on the desktop which numbers to keep
    /// up to date.
    static let widgetKindPrefix = "fr.simplibot.simplybar."
    static let storageWidgetKind = widgetKindPrefix + "storage"
    static let gpuWidgetKind = widgetKindPrefix + "gpu"
    static let bluetoothWidgetKind = widgetKindPrefix + "bluetooth"
    static let keepAwakeWidgetKind = widgetKindPrefix + "keepAwake"
    static let healthWidgetKind = widgetKindPrefix + "health"

    /// Darwin notification the Keep Awake widget posts after writing its request. Under the App Group's name, the
    /// prefix the sandbox lets the app and its extension share.
    static let keepAwakeNotification = appGroup + ".keepAwake"

    private static let fileName = "widget-payload.json"
    private static let requestFileName = "keep-awake-request.json"

    static var fileURL: URL? { url(of: fileName) }

    private static func url(of name: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(name, isDirectory: false)
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
        try write(encode(payload), to: fileName)
    }

    static func load() -> WidgetPayload? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    // MARK: - Keep Awake requests

    static func encode(_ request: KeepAwakeRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(request)
    }

    static func decodeRequest(_ data: Data) throws -> KeepAwakeRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(KeepAwakeRequest.self, from: data)
    }

    /// Written by the widget's intent, then announced with `postKeepAwakeRequest()`.
    static func saveKeepAwakeRequest(_ request: KeepAwakeRequest) throws {
        try write(encode(request), to: requestFileName)
    }

    static func loadKeepAwakeRequest() -> KeepAwakeRequest? {
        guard let url = url(of: requestFileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? decodeRequest(data)
    }

    static func postKeepAwakeRequest() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(keepAwakeNotification as CFString), nil, nil, true
        )
    }

    private static func write(_ data: Data, to name: String) throws {
        guard let url = url(of: name) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func isFresh(_ payload: WidgetPayload, now: Date = .now) -> Bool {
        now.timeIntervalSince(payload.date) < freshness
    }
}
