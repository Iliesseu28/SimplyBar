import Foundation
import SwiftUI

/// How the Mac is doing, from best to worst: verdicts compare by severity.
nonisolated enum DiagnosticVerdict: String, CaseIterable, Codable, Sendable, Comparable {
    case ok, watch, problem

    private var rank: Int {
        switch self {
        case .ok: 0
        case .watch: 1
        case .problem: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    var title: LocalizedStringResource {
        switch self {
        case .ok: "OK"
        case .watch: "Worth watching"
        case .problem: "Problem"
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .watch: "exclamationmark.circle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .ok: .green
        case .watch: .orange
        case .problem: .red
        }
    }
}

/// What a diagnostic button does. Every case works inside the App Sandbox, and runs only when the user clicks it:
/// the model never acts, it can only offer these buttons.
nonisolated enum DiagnosticAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case openActivityMonitor, openStorageSettings, openBatterySettings, keepAwakeOneHour, openAlerts
    /// Offered by the app when Apple Intelligence is turned off, never by the model.
    case openAppleIntelligenceSettings

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .openActivityMonitor: "Activity Monitor"
        case .openStorageSettings: "Storage Settings"
        case .openBatterySettings: "Battery Settings"
        case .keepAwakeOneHour: "Keep Awake for 1 Hour"
        case .openAlerts: "Set Up Alerts"
        case .openAppleIntelligenceSettings: "Apple Intelligence Settings"
        }
    }

    var symbol: String {
        switch self {
        case .openActivityMonitor: "chart.bar.xaxis"
        case .openStorageSettings: "internaldrive"
        case .openBatterySettings: "battery.75percent"
        case .keepAwakeOneHour: "cup.and.saucer"
        case .openAlerts: "bell.badge"
        case .openAppleIntelligenceSettings: "sparkles"
        }
    }
}

/// Who wrote the text of a diagnostic.
nonisolated enum DiagnosticSource: String, Codable, Sendable {
    /// Apple's on-device model, checked against the rules.
    case ai
    /// The fixed rules alone: always available, in every language of the app.
    case rules
}

/// A diagnostic card: a verdict, a short title, two sentences and up to three buttons.
nonisolated struct DiagnosticReport: Codable, Equatable, Sendable {
    static let maximumActions = 3

    var verdict: DiagnosticVerdict
    var title: String
    var explanation: String
    var actions: [DiagnosticAction]
    var source: DiagnosticSource
    var date: Date

    init(verdict: DiagnosticVerdict, title: String, explanation: String, actions: [DiagnosticAction],
         source: DiagnosticSource, date: Date) {
        self.verdict = verdict
        self.title = title
        self.explanation = explanation
        self.actions = actions
        self.source = source
        self.date = date
    }

    /// An action a later version removed, or a missing list, leaves the others.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try values.decode(DiagnosticVerdict.self, forKey: .verdict)
        title = try values.decode(String.self, forKey: .title)
        explanation = try values.decode(String.self, forKey: .explanation)
        let names = (try? values.decodeIfPresent([String].self, forKey: .actions)) ?? []
        actions = names.compactMap(DiagnosticAction.init(rawValue:))
        source = (try? values.decodeIfPresent(DiagnosticSource.self, forKey: .source)) ?? .rules
        date = try values.decode(Date.self, forKey: .date)
    }
}

/// The diagnostic as the app last wrote it for the widget; nil in the payload when the app is not running (it
/// removes it when it quits).
nonisolated struct DiagnosticStatus: Codable, Equatable, Sendable {
    /// Nil until a first diagnostic ran since the app started.
    var report: DiagnosticReport?
    /// Date of the last widget request the app handled: the widget waits for it.
    var requestDate: Date?

    init(report: DiagnosticReport?, requestDate: Date? = nil) {
        self.report = report
        self.requestDate = requestDate
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        report = try? values.decodeIfPresent(DiagnosticReport.self, forKey: .report)
        requestDate = try? values.decodeIfPresent(Date.self, forKey: .requestDate)
    }
}

/// What a click on the widget's Analyze button asks for. The extension cannot run the diagnostic (it does not link
/// the model and quits right after the click): it writes this request and posts `SharedStore.diagnosticNotification`.
nonisolated struct DiagnosticRequest: Codable, Equatable, Sendable {
    var date: Date

    /// Handled once, and only while the widget still shows it as pending.
    func isNew(after handled: Date?, now: Date) -> Bool {
        now.timeIntervalSince(date) < DiagnosticWidgetState.pendingWindow && (handled.map { date > $0 } ?? true)
    }
}

/// What the Diagnostic widget shows.
nonisolated struct DiagnosticWidgetState: Equatable, Sendable {
    /// A diagnostic with Apple Intelligence takes a few seconds: past this, the widget stops waiting for the app.
    static let pendingWindow: TimeInterval = 30

    var report: DiagnosticReport?
    /// Asked from the widget, not answered yet.
    var isPending: Bool
    /// When the app wrote the state.
    var date: Date

    /// Nil when the app is not running: no fresh file, or no diagnostic status in it.
    static func resolve(payload: WidgetPayload?, request: DiagnosticRequest?, now: Date = .now) -> DiagnosticWidgetState? {
        guard let payload, SharedStore.isFresh(payload, now: now), let status = payload.diagnostic else { return nil }
        let pending = request.map {
            $0.date > status.requestDate ?? .distantPast && now.timeIntervalSince($0.date) < pendingWindow
        } ?? false
        return DiagnosticWidgetState(report: status.report, isPending: pending, date: payload.date)
    }
}
