import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// A disk offered in the widget's settings, from the list the app last wrote.
struct DiskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Disk"
    static let defaultQuery = DiskQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DiskQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DiskEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DiskEntity] {
        Self.all()
    }

    private static func all() -> [DiskEntity] {
        (SharedStore.load()?.volumes ?? []).map { DiskEntity(id: $0.id, name: $0.name) }
    }
}

/// The disk the small widget shows, and the larger sizes list first. None chosen: the startup disk.
struct SelectDiskIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Disk"

    @Parameter(title: "Disk")
    var disk: DiskEntity?
}

// MARK: - Timeline

struct StorageEntry: TimelineEntry {
    let date: Date
    /// Nil when the app has not written anything recent (not running).
    let payload: WidgetPayload?
    let diskID: String?

    /// The chosen disk first, then the others in the app's order (startup disk, internal, external).
    var volumes: [VolumeSample] {
        var volumes = payload?.volumes ?? []
        if let diskID, let index = volumes.firstIndex(where: { $0.id == diskID }) {
            volumes.insert(volumes.remove(at: index), at: 0)
        }
        return volumes
    }
}

struct StorageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StorageEntry {
        StorageEntry(date: .now, payload: .preview, diskID: nil)
    }

    func snapshot(for configuration: SelectDiskIntent, in context: Context) async -> StorageEntry {
        let payload = SharedStore.load()
        let shown: WidgetPayload? = context.isPreview && payload?.volumes == nil ? WidgetPayload.preview : payload
        return StorageEntry(date: .now, payload: shown, diskID: configuration.disk?.id)
    }

    func timeline(for configuration: SelectDiskIntent, in context: Context) async -> Timeline<StorageEntry> {
        let (payload, policy) = PayloadTimeline.current()
        let entry = StorageEntry(date: .now, payload: payload, diskID: configuration.disk?.id)
        return Timeline(entries: [entry], policy: policy)
    }
}

// MARK: - Widget

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedStore.storageWidgetKind, intent: SelectDiskIntent.self, provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Storage")
        .description("Used, free and purgeable space on every disk.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StorageWidgetView: View {
    let entry: StorageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let volumes = entry.volumes
        if let payload = entry.payload, let first = volumes.first {
            switch family {
            case .systemSmall: SmallStorageView(volume: first, date: payload.date)
            case .systemLarge: StorageListView(volumes: Array(volumes.prefix(5)), date: payload.date, detailed: true)
            default: StorageListView(volumes: Array(volumes.prefix(2)), date: payload.date, detailed: false)
            }
        } else if entry.payload != nil {
            // The app writes the disks at its next widget check, within 5 minutes of the widget being placed.
            NotRunningView(symbol: "internaldrive", title: "Storage", message: "Disks appear within 5 minutes.")
        } else {
            NotRunningView(symbol: "internaldrive", title: "Storage")
        }
    }
}

// MARK: - Views

private struct SmallStorageView: View {
    let volume: VolumeSample
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(symbol: volume.symbol, name: volume.name, value: Format.percent(volume.usage), date: date)
            StorageBar(volume: volume, height: 22)
            VStack(spacing: 2) {
                Text("\(gigabytes(volume.used)) of \(gigabytes(volume.total)) GB")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(gigabytes(volume.free)) GB free")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let purgeable = volume.shownPurgeable {
                    Text("Including \(gigabytes(purgeable)) GB purgeable")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StorageListView: View {
    let volumes: [VolumeSample]
    let date: Date
    /// Large size: one more line per disk, with used and purgeable space.
    let detailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: detailed ? 12 : 7) {
            WidgetHeader(symbol: "internaldrive", title: "Storage", date: date)
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: volume.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(verbatim: volume.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(gigabytes(volume.free)) GB free").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(verbatim: Format.percent(volume.usage)).font(.system(size: 12, weight: .bold))
                    }
                    StorageBar(volume: volume, height: detailed ? 16 : 14)
                    if detailed {
                        HStack {
                            Text("\(gigabytes(volume.used)) of \(gigabytes(volume.total)) GB")
                            Spacer(minLength: 4)
                            if let purgeable = volume.shownPurgeable {
                                Text("Including \(gigabytes(purgeable)) GB purgeable")
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Used space in its threshold color (green, orange, red), then purgeable space in grey, then free space.
private struct StorageBar: View {
    let volume: VolumeSample
    let height: CGFloat

    var body: some View {
        let total = max(volume.total, 1)
        TickBar(stacked: [
            (volume.used / total, Palette.storage(volume.usage)),
            ((volume.purgeable ?? 0) / total, Palette.purgeable),
        ], height: height)
    }
}

/// Whole gigabytes for large disks, one decimal under 100 GB.
private func gigabytes(_ bytes: Double) -> String {
    Format.diskGigabytes(bytes, decimals: bytes < 100_000_000_000 ? 1 : 0)
}

private extension VolumeSample {
    var symbol: String { isInternal ? "internaldrive" : "externaldrive" }

    /// Purgeable space worth a line: at least 0.1 GB.
    var shownPurgeable: Double? {
        guard let purgeable, purgeable >= 100_000_000 else { return nil }
        return purgeable
    }
}
