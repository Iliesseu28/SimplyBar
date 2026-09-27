import SwiftUI
import WidgetKit

@main
struct SimplyBarWidgets: WidgetBundle {
    var body: some Widget {
        CPUWidget()
        MemoryWidget()
        NetworkWidget()
        DiskWidget()
        StorageWidget()
    }
}

// MARK: - Timeline

struct PayloadEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has not written anything recent (not running).
    let payload: WidgetPayload?
}

/// Every widget reads the file the menu bar app writes; the app reloads the timelines every 30 minutes.
struct PayloadProvider: TimelineProvider {
    func placeholder(in context: Context) -> PayloadEntry {
        PayloadEntry(date: .now, payload: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (PayloadEntry) -> Void) {
        let payload = SharedStore.load()
        completion(PayloadEntry(date: .now, payload: context.isPreview ? (payload ?? .preview) : payload))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PayloadEntry>) -> Void) {
        let (payload, policy) = PayloadTimeline.current()
        completion(Timeline(entries: [PayloadEntry(date: .now, payload: payload)], policy: policy))
    }
}

enum PayloadTimeline {
    /// The latest numbers while they are fresh, and when to look again. Fresh numbers are redrawn when the app
    /// reloads the timelines. If the app stops, the widget switches to "not running" once the numbers get too old;
    /// without numbers it waits for the app's next reload.
    static func current(now: Date = .now) -> (WidgetPayload?, TimelineReloadPolicy) {
        let payload = SharedStore.load().flatMap { SharedStore.isFresh($0, now: now) ? $0 : nil }
        let policy: TimelineReloadPolicy = payload.map { .after($0.date.addingTimeInterval(SharedStore.freshness)) } ?? .never
        return (payload, policy)
    }
}

extension WidgetPayload {
    static let preview = WidgetPayload(
        date: .now,
        cpu: CPUSample(user: 0.18, system: 0.07, idle: 0.75, perCore: []),
        cpuHistory: [0.2, 0.3, 0.25, 0.4, 0.6, 0.35, 0.3, 0.2, 0.25, 0.3, 0.5, 0.45, 0.3, 0.2, 0.22, 0.28, 0.35, 0.3, 0.26, 0.25],
        memory: MemorySample(total: 17_179_869_184, app: 4_300_000_000, wired: 1_900_000_000, compressed: 1_600_000_000),
        network: NetworkSample(upload: 42_000, download: 830_000),
        uploadHistory: [2, 5, 3, 8, 4, 2, 6, 3, 9, 4, 3, 2, 5, 7, 3, 4, 2, 6, 3, 4].map { $0 * 10_000 },
        downloadHistory: [8, 20, 12, 30, 15, 9, 25, 14, 40, 18, 10, 8, 22, 35, 12, 16, 9, 28, 13, 83].map { $0 * 10_000 },
        disk: DiskSample(name: "Macintosh HD", total: 245_110_000_000, free: 108_560_000_000),
        volumes: [
            VolumeSample(id: "/", name: "Macintosh HD", isInternal: true, total: 245_110_000_000, free: 108_560_000_000,
                         purgeable: 3_480_000_000),
            VolumeSample(id: "/Volumes/External",
                         name: String(localized: "External", comment: "Name of the sample external disk in the widget gallery preview."),
                         isInternal: false, total: 1_023_000_000_000,
                         free: 212_000_000_000, purgeable: nil),
        ]
    )
}

// MARK: - Widgets

struct CPUWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKindPrefix + "cpu", provider: PayloadProvider()) { entry in
            CPUWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CPU")
        .description("CPU load and its recent history.")
        .supportedFamilies([.systemSmall])
    }
}

struct MemoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKindPrefix + "memory", provider: PayloadProvider()) { entry in
            MemoryWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("RAM")
        .description("Memory in use and how it splits.")
        .supportedFamilies([.systemSmall])
    }
}

struct NetworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKindPrefix + "network", provider: PayloadProvider()) { entry in
            NetworkWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Network")
        .description("Download and upload speeds.")
        .supportedFamilies([.systemSmall])
    }
}

struct DiskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKindPrefix + "disk", provider: PayloadProvider()) { entry in
            DiskWidgetView(payload: entry.payload).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("SSD")
        .description("Space used on the startup disk.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Views

struct WidgetHeader: View {
    let symbol: String
    let title: Text
    var value: String?
    /// When the numbers were measured: widgets are redrawn every 30 minutes, not live.
    var date: Date?

    init(symbol: String, title: LocalizedStringKey, value: String? = nil, date: Date? = nil) {
        self.init(symbol: symbol, title: Text(title), value: value, date: date)
    }

    /// A title that is not translated, such as a disk name.
    init(symbol: String, name: String, value: String? = nil, date: Date? = nil) {
        self.init(symbol: symbol, title: Text(verbatim: name), value: value, date: date)
    }

    private init(symbol: String, title: Text, value: String?, date: Date?) {
        self.symbol = symbol
        self.title = title
        self.value = value
        self.date = date
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let date {
                    // A fixed time: `Text(date, style: .time)` makes WidgetKit keep room for a wider live date, which
                    // cut the line short. Where the label does not fit beside the value, the time shows alone.
                    let time = Text(date, format: .dateTime.hour().minute())
                    ViewThatFits(in: .horizontal) {
                        Text("Updated \(time)")
                        time
                    }
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if let value {
                Text(value).font(.system(size: 20, weight: .bold)).monospacedDigit().widgetAccentable().fixedSize()
            }
        }
    }
}

struct NotRunningView: View {
    let symbol: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey = "Open SimplyBar to start measuring."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(symbol: symbol, title: title)
            Spacer()
            Text(message)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct CPUWidgetView: View {
    let payload: WidgetPayload?

    var body: some View {
        if let payload, let cpu = payload.cpu {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: "cpu", title: "CPU", value: Format.percent(cpu.total), date: payload.date)
                TickBar(value: cpu.total, height: 22)
                HistoryChart(
                    values: payload.cpuHistory, capacity: WidgetPayload.historyLength,
                    scale: ChartScale(values: payload.cpuHistory, minimum: 0.1),
                    barColor: { Palette.load($0) }, axisLabel: { Format.percent($0) }, labelWidth: 0
                )
            }
        } else {
            NotRunningView(symbol: "cpu", title: "CPU")
        }
    }
}

struct MemoryWidgetView: View {
    let payload: WidgetPayload?

    var body: some View {
        if let payload, let memory = payload.memory {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: "memorychip", title: "RAM", value: Format.percent(memory.usage), date: payload.date)
                TickBar(stacked: [
                    (memory.app / memory.total, Palette.app),
                    (memory.wired / memory.total, Palette.wired),
                    (memory.compressed / memory.total, Palette.compressed),
                ], height: 22)
                VStack(spacing: 3) {
                    row("Apps", memory.app, Palette.app)
                    row("Wired", memory.wired, Palette.wired)
                    row("Compressed", memory.compressed, Palette.compressed)
                }
            }
        } else {
            NotRunningView(symbol: "memorychip", title: "RAM")
        }
    }

    private func row(_ title: LocalizedStringKey, _ bytes: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(verbatim: "\(Format.memoryGigabytes(bytes)) \(String(localized: "GB"))").monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

struct NetworkWidgetView: View {
    let payload: WidgetPayload?

    var body: some View {
        if let payload, let network = payload.network {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(symbol: "network", title: "Network", date: payload.date)
                HStack {
                    speed(arrow: "arrow.down", bytes: network.download)
                    speed(arrow: "arrow.up", bytes: network.upload)
                }
                MirrorChart(
                    up: payload.downloadHistory, down: payload.uploadHistory, capacity: WidgetPayload.historyLength,
                    upScale: ChartScale(values: payload.downloadHistory, minimum: 10_000),
                    downScale: ChartScale(values: payload.uploadHistory, minimum: 10_000),
                    upColor: Palette.download, downColor: Palette.upload,
                    axisLabel: { _ in "" }, labelWidth: 0
                )
            }
        } else {
            NotRunningView(symbol: "network", title: "Network")
        }
    }

    private func speed(arrow: String, bytes: Double) -> some View {
        let parts = Format.speed(bytes)
        return VStack(spacing: 0) {
            Image(systemName: arrow).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: parts.value).font(.system(size: 17, weight: .bold)).monospacedDigit().widgetAccentable()
            Text(verbatim: parts.unit.label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DiskWidgetView: View {
    let payload: WidgetPayload?

    var body: some View {
        if let payload, let disk = payload.disk {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: "internaldrive", title: "SSD", value: Format.percent(disk.usage), date: payload.date)
                TickBar(gradientValue: disk.usage, height: 22)
                VStack(spacing: 2) {
                    Text("\(Format.diskGigabytes(disk.used, decimals: 0)) of \(Format.diskGigabytes(disk.total, decimals: 0)) GB")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(Format.diskGigabytes(disk.free, decimals: 0)) GB free")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            }
        } else {
            NotRunningView(symbol: "internaldrive", title: "SSD")
        }
    }
}
