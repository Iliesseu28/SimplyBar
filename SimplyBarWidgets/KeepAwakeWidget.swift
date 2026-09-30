import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Intent

/// Turns Keep Awake on or off from the widget. It runs in the widget extension, which quits right after and so cannot
/// hold the power assertion: it leaves a request for the app, then waits a moment for the app's answer (the request's
/// date written back), because WidgetKit redraws the widget as soon as it returns.
struct SetKeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Awake"
    static let isDiscoverable = false

    @Parameter(title: "Keep Awake")
    var isActive: Bool

    init() {}

    init(isActive: Bool) {
        self.isActive = isActive
    }

    func perform() async throws -> some IntentResult {
        let request = KeepAwakeRequest(isActive: isActive, date: .now)
        try SharedStore.saveKeepAwakeRequest(request)
        SharedStore.postKeepAwakeRequest()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let answered = SharedStore.load()?.keepAwake?.requestDate, answered >= request.date { break }
        }
        return .result()
    }
}

// MARK: - Timeline

struct KeepAwakeEntry: TimelineEntry {
    let date: Date
    /// Nil when the app is not running.
    let state: KeepAwakeWidgetState?
}

struct KeepAwakeProvider: TimelineProvider {
    private static let preview = KeepAwakeWidgetState(isActive: true, end: nil, isPending: false, date: .now)

    func placeholder(in context: Context) -> KeepAwakeEntry {
        KeepAwakeEntry(date: .now, state: Self.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (KeepAwakeEntry) -> Void) {
        let state = KeepAwakeWidgetState.resolve(payload: SharedStore.load(), request: SharedStore.loadKeepAwakeRequest())
        completion(KeepAwakeEntry(date: .now, state: context.isPreview ? (state ?? Self.preview) : state))
    }

    /// One entry now, then one when a timed session ends, one when an unanswered request stops being shown, and one
    /// when the app's word gets too old ("not running").
    func getTimeline(in context: Context, completion: @escaping (Timeline<KeepAwakeEntry>) -> Void) {
        let now = Date.now
        let payload = SharedStore.load()
        let request = SharedStore.loadKeepAwakeRequest()
        var dates = [now]
        if let end = payload?.keepAwake?.end { dates.append(end) }
        if let request { dates.append(request.date.addingTimeInterval(KeepAwakeWidgetState.pendingWindow)) }
        if let payload { dates.append(payload.date.addingTimeInterval(SharedStore.freshness)) }
        let entries = dates.filter { $0 >= now }.sorted().map {
            KeepAwakeEntry(date: $0, state: KeepAwakeWidgetState.resolve(payload: payload, request: request, now: $0))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

// MARK: - Widget

struct KeepAwakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.keepAwakeWidgetKind, provider: KeepAwakeProvider()) { entry in
            KeepAwakeWidgetView(state: entry.state).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Keep Awake")
        .description("Keeps this Mac awake, on or off in one click.")
        .supportedFamilies([.systemSmall])
    }
}

struct KeepAwakeWidgetView: View {
    let state: KeepAwakeWidgetState?

    private static let symbol = "cup.and.saucer"

    var body: some View {
        if let state {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(symbol: Self.symbol, title: "Keep Awake", date: state.date)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Image(systemName: state.isActive ? "cup.and.saucer.fill" : Self.symbol)
                        .font(.system(size: 26))
                        .foregroundStyle(state.isActive ? Palette.green : Color.secondary)
                        .widgetAccentable()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.isActive ? "On" : "Off")
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if state.isActive, !state.isPending {
                            Group {
                                if let end = state.end {
                                    Text("Until \(Text(end, format: .dateTime.hour().minute()))")
                                } else {
                                    Text("Indefinitely")
                                }
                            }
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }
                .invalidatableContent()
                Spacer(minLength: 0)
                Button(intent: SetKeepAwakeIntent(isActive: !state.isActive)) {
                    Text(state.isActive ? "Turn Off" : "Turn On")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } else {
            // A click on the widget opens the app.
            NotRunningView(symbol: Self.symbol, title: "Keep Awake", message: "Open SimplyBar to keep this Mac awake.")
        }
    }
}
