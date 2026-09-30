import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Intent

/// Asks the app for a diagnostic. The extension does not link Apple's model and quits right after the click: it
/// leaves a request for the app and returns at once. The widget shows "Analyzing" until the app writes the result
/// and reloads it, a few seconds later.
struct RunDiagnosticIntent: AppIntent {
    static let title: LocalizedStringResource = "Analyze"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        try SharedStore.saveDiagnosticRequest(DiagnosticRequest(date: .now))
        SharedStore.postDiagnosticRequest()
        return .result()
    }
}

// MARK: - Timeline

struct DiagnosticEntry: TimelineEntry {
    let date: Date
    /// Nil when the app is not running.
    let state: DiagnosticWidgetState?
}

struct DiagnosticProvider: TimelineProvider {
    func placeholder(in context: Context) -> DiagnosticEntry {
        DiagnosticEntry(date: .now, state: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DiagnosticEntry) -> Void) {
        let state = DiagnosticWidgetState.resolve(payload: SharedStore.load(), request: SharedStore.loadDiagnosticRequest())
        completion(DiagnosticEntry(date: .now, state: context.isPreview ? (state ?? .preview) : state))
    }

    /// One entry now, one when an unanswered request stops being shown, and one when the app's word gets too old.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DiagnosticEntry>) -> Void) {
        let now = Date.now
        let payload = SharedStore.load()
        let request = SharedStore.loadDiagnosticRequest()
        var dates = [now]
        if let request { dates.append(request.date.addingTimeInterval(DiagnosticWidgetState.pendingWindow)) }
        if let payload { dates.append(payload.date.addingTimeInterval(SharedStore.freshness)) }
        let entries = dates.filter { $0 >= now }.sorted().map {
            DiagnosticEntry(date: $0, state: DiagnosticWidgetState.resolve(payload: payload, request: request, now: $0))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

extension DiagnosticWidgetState {
    static let preview = DiagnosticWidgetState(
        report: DiagnosticReport(
            verdict: .ok, title: String(localized: "Your Mac is doing fine"),
            explanation: String(localized: "Processor, memory, disks and heat are within normal limits."),
            actions: [], source: .rules, date: .now
        ),
        isPending: false, date: .now
    )
}

// MARK: - Widget

struct DiagnosticWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.diagnosticWidgetKind, provider: DiagnosticProvider()) { entry in
            DiagnosticWidgetView(state: entry.state).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Diagnostic")
        .description("How your Mac is doing, checked in one click.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DiagnosticWidgetView: View {
    let state: DiagnosticWidgetState?
    @Environment(\.widgetFamily) private var family

    static let symbol = "stethoscope"

    var body: some View {
        if let state {
            DiagnosticWidgetContent(state: state, isMedium: family == .systemMedium)
        } else {
            // A click on the widget opens the app.
            NotRunningView(symbol: Self.symbol, title: "Diagnostic", message: "Open SimplyBar to check this Mac.")
        }
    }
}

/// The widget's drawing for a family, also used by the screenshot renderer.
struct DiagnosticWidgetContent: View {
    let state: DiagnosticWidgetState
    let isMedium: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(symbol: DiagnosticWidgetView.symbol, title: "Diagnostic", date: state.report?.date)
            Spacer(minLength: 0)
            if let report = state.report {
                HStack(spacing: 5) {
                    Image(systemName: report.verdict.symbol).foregroundStyle(report.verdict.color).widgetAccentable()
                    Text(report.verdict.title).foregroundStyle(report.verdict.color)
                }
                .font(.system(size: 12, weight: .semibold))
                Text(report.title)
                    .font(.system(size: isMedium ? 14 : 13, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.8)
                if isMedium {
                    Text(report.explanation)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text("No diagnostic yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(intent: RunDiagnosticIntent()) {
                Text(state.isPending ? "Analyzing…" : "Analyze")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(state.isPending)
        }
        .invalidatableContent()
    }
}
