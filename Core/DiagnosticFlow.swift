import Foundation

/// The order of one diagnostic, apart from the app so the tests can follow it: the rules read the snapshot, the
/// last card is reused when nothing changed notably, and only then is anything of the model made.
nonisolated enum DiagnosticPipeline {
    enum Outcome: Equatable, Sendable {
        /// The last card, still right.
        case reused(DiagnosticReport)
        /// The model's card, past `DiagnosticGuard`.
        case written(DiagnosticReport)
        /// The rules' card, with why the model's is missing: nil when there is no model to ask.
        case rules(DiagnosticReport, AIFailure?)
        /// Stopped before the end: the card stays as it was.
        case cancelled
    }

    typealias Writer = (_ findings: [DiagnosticFinding], _ rules: DiagnosticReport) async -> Result<DiagnosticReport, AIFailure>

    /// - Parameter write: makes the model's session and writes the card; nil when the model cannot write. Called
    ///   only when the cache has nothing: a reused card costs no session.
    static func run(snapshot: MacSnapshot, cache: DiagnosticCache?, locale: Locale, now: Date = .now,
                    write: Writer?) async -> Outcome {
        let findings = DiagnosticRules.findings(snapshot)
        let rules = DiagnosticRules.report(snapshot, findings: findings, now: now, locale: locale)
        if let cached = cache?.reusable(for: snapshot, findings: findings, now: now) { return .reused(cached) }
        guard let write else { return .rules(rules, nil) }
        guard !Task.isCancelled else { return .cancelled }
        let result = await write(findings, rules)
        if Task.isCancelled { return .cancelled }
        switch result {
        case .success(let report): return .written(report)
        case .failure(.cancelled): return .cancelled
        case .failure(let failure): return .rules(rules, failure)
        }
    }
}

/// What the Diagnostic card shows. The model's text reaches it only once `DiagnosticGuard` accepted it: while the
/// model writes, the card says so, with the rules' verdict.
nonisolated struct DiagnosticCardState: Equatable, Sendable {
    enum Display: Equatable, Sendable {
        /// Measuring (no card yet), or the model writing, with the rules' verdict.
        case analyzing(DiagnosticVerdict?)
        case report(DiagnosticReport)
    }

    /// The last card accepted: the model's after its checks, or the rules'.
    private(set) var report: DiagnosticReport?
    /// Why the card comes from the rules although the model is there.
    private(set) var failure: AIFailure?
    /// The rules' verdict while the model writes.
    private(set) var writing: DiagnosticVerdict?

    init(report: DiagnosticReport? = nil, failure: AIFailure? = nil) {
        self.report = report
        self.failure = failure
    }

    var display: Display {
        if let writing { return .analyzing(writing) }
        if let report { return .report(report) }
        return .analyzing(nil)
    }

    /// The model starts writing a card for these rules.
    mutating func startWriting(verdict: DiagnosticVerdict) {
        writing = verdict
    }

    /// A diagnostic ended. A cancelled one leaves the card and its note as they were.
    mutating func finish(_ outcome: DiagnosticPipeline.Outcome) {
        writing = nil
        switch outcome {
        case .reused(let report), .written(let report):
            self.report = report
            failure = nil
        case .rules(let report, let failure):
            self.report = report
            self.failure = failure
        case .cancelled:
            break
        }
    }
}
