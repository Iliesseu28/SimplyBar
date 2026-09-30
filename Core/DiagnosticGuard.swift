import Foundation
import NaturalLanguage

/// What the model wrote, before any check. The title is not the model's: the rules' one, already in every language,
/// names the main finding.
nonisolated struct DiagnosticCandidate: Equatable, Sendable {
    var verdict: DiagnosticVerdict
    var explanation: String
    var actions: [DiagnosticAction]
}

/// Checks the model's text against the facts and the rules; on any failure the rules text is shown instead.
nonisolated enum DiagnosticGuard {
    enum Rejection: String, Error, Sendable {
        /// Less severe than the rules: the model would hide a problem.
        case verdictBelowRules
        /// More severe than the rules: the model judged a threshold itself.
        case verdictAboveRules
        /// A button outside the list, or whose condition does not hold (no "free up space" while the disk is fine).
        case actionNotAllowed
        /// A number that is in neither the facts nor the findings.
        case inventedNumber
        case emptyText
        case tooLong
    }

    static let maximumExplanationLength = 400
    /// A longer question is cut: the model's context is small, and no question about a Mac needs more.
    static let maximumQuestionLength = 500

    /// The report to show, under the rules' title, or why the model's text was set aside.
    static func validate(_ candidate: DiagnosticCandidate, rules: DiagnosticReport, allowed: [DiagnosticAction],
                         facts: String, now: Date = .now) -> Result<DiagnosticReport, Rejection> {
        let explanation = display(candidate.explanation)
        guard !explanation.isEmpty else { return .failure(.emptyText) }
        guard explanation.count <= maximumExplanationLength else { return .failure(.tooLong) }
        if candidate.verdict < rules.verdict { return .failure(.verdictBelowRules) }
        if candidate.verdict > rules.verdict { return .failure(.verdictAboveRules) }
        guard candidate.actions.allSatisfy(allowed.contains) else { return .failure(.actionNotAllowed) }
        guard unknownNumbers(in: explanation, facts: facts).isEmpty else { return .failure(.inventedNumber) }
        var actions: [DiagnosticAction] = []
        for action in candidate.actions where !actions.contains(action) { actions.append(action) }
        return .success(DiagnosticReport(
            verdict: candidate.verdict, title: rules.title, explanation: explanation,
            actions: Array(actions.prefix(DiagnosticReport.maximumActions)), source: .ai, date: now
        ))
    }

    /// The model's text as the owner reads it: names keep their words, lose the ⟦ ⟧ that set them apart.
    static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The buttons of an answer: only when the model read the Mac for it (an off-topic question gets none), only
    /// those whose condition holds now, at most two.
    static func answerActions(_ actions: [DiagnosticAction], toolCalls: [String], snapshot: MacSnapshot) -> [DiagnosticAction] {
        guard !toolCalls.isEmpty else { return [] }
        let findings = DiagnosticRules.findings(snapshot)
        var kept: [DiagnosticAction] = []
        for action in actions where !kept.contains(action)
            && DiagnosticRules.allows(action, findings: findings, snapshot: snapshot) {
            kept.append(action)
        }
        return Array(kept.prefix(maximumAnswerActions))
    }

    static let maximumAnswerActions = 2

    // MARK: - Answers

    /// Why an answer of the conversation cannot be shown, or nil. Like the card, it may cite only numbers it was
    /// given: the tools' facts, the snapshot, the owner's questions (`reference`).
    static func rejection(ofAnswer text: String, reference: String) -> Rejection? {
        if display(text).isEmpty { return .emptyText }
        return unknownNumbers(in: text, facts: reference).isEmpty ? nil : .inventedNumber
    }

    /// The answer to show once the checked one is in English: its translation when there is one that keeps to the
    /// facts, otherwise the English answer itself, already checked.
    static func answerText(checked: String, translation: String?, reference: String) -> String {
        guard let translation, rejection(ofAnswer: translation, reference: reference) == nil else { return checked }
        return translation
    }

    /// The facts the model gets, the reference for the numbers it may cite.
    static func referenceFacts(_ snapshot: MacSnapshot, findings: [DiagnosticFinding]) -> String {
        ([snapshot.facts] + findings.map { $0.fact(snapshot) }).joined(separator: "\n")
    }

    // MARK: - Language

    /// The language a text is written in, as a code like `fr` or `ja`. Names between ⟦ ⟧ and numbers are left out:
    /// "⟦Magic Mouse⟧ 8 %" would read as English in a Japanese sentence.
    static func language(of text: String) -> String? {
        let words = text.replacingOccurrences(of: #"⟦[^⟧]*⟧"#, with: " ", options: .regularExpression)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)
        return recognizer.dominantLanguage.map { Locale(identifier: $0.rawValue).language.languageCode?.identifier ?? $0.rawValue }
    }

    /// The text is in the language asked for. Only English counts as wrong: it is what the model slips into, since
    /// the facts are in English; a close language misread (Norwegian for Danish) is not worth a second pass.
    static func isWritten(_ text: String, in language: DiagnosticLanguage) -> Bool {
        let expected = language.locale.language.languageCode?.identifier ?? language.code
        return expected == "en" || Self.language(of: text) != "en"
    }

    // MARK: - Numbers

    /// Every number of a text, in any script (Arabic-Indic, Devanagari… digits count too), with a dot or a comma as
    /// decimal separator: "1,5" and "1.5" both give 1.5. A separator before exactly three digits groups thousands
    /// ("1 000", "1,000", "1.000" give 1000): the facts never have three decimals.
    static func numbers(in text: String) -> [Double] {
        let ascii = String(text.map { character -> Character in
            guard character.isNumber, let digit = character.wholeNumberValue, (0...9).contains(digit) else { return character }
            return Character(String(digit))
        })
        let grouped = ascii.replacingOccurrences(
            of: #"(?<=\d)[\u00A0\u202F ,.'’](?=\d{3}(?!\d))"#, with: "", options: .regularExpression
        )
        let pattern = /\d+(?:[.,]\d+)?/
        return grouped.matches(of: pattern).compactMap {
            Double(String($0.output).replacingOccurrences(of: ",", with: "."))
        }
    }

    /// The numbers of a text that match none of the facts. A rounded figure counts: 12 for 12.4, 1 for 0.8.
    static func unknownNumbers(in text: String, facts: String) -> [Double] {
        let known = numbers(in: facts)
        return numbers(in: text).filter { value in
            !known.contains { abs($0 - value) < 0.05 || ($0.rounded() == value && value == value.rounded()) }
        }
    }
}

// MARK: - Cache

/// The last diagnostic written by the model, kept while nothing notable changes.
nonisolated struct DiagnosticCache: Equatable, Sendable {
    /// No new model diagnostic within this time when the Mac looks the same.
    static let lifetime: TimeInterval = 120

    var snapshot: MacSnapshot
    var findings: [DiagnosticFinding]
    var report: DiagnosticReport

    /// The report again, when it is recent, the findings are the same and no reading moved notably.
    func reusable(for snapshot: MacSnapshot, findings: [DiagnosticFinding], now: Date) -> DiagnosticReport? {
        guard report.source == .ai, now.timeIntervalSince(report.date) < Self.lifetime, now >= report.date,
              findings == self.findings, !snapshot.differsNotably(from: self.snapshot) else { return nil }
        return report
    }
}

// MARK: - Availability and errors

/// Whether the on-device model can write the diagnostic, as the interface tells it.
nonisolated enum AIStatus: Equatable, Sendable {
    case available
    /// macOS 14 or 15.
    case systemTooOld
    /// An Intel Mac, or a Mac Apple Intelligence does not run on.
    case deviceNotEligible
    case appleIntelligenceOff
    /// Model still downloading or preparing.
    case modelNotReady
    /// The app's language, one the model does not write; the name is in that language.
    case languageNotSupported(String)

    /// Why the rules wrote the diagnostic; nil when the model can.
    var message: String? {
        switch self {
        case .available: nil
        case .systemTooOld: String(localized: "Apple Intelligence needs macOS 26 or later.")
        case .deviceNotEligible: String(localized: "This Mac does not support Apple Intelligence.")
        case .appleIntelligenceOff: String(localized: "Apple Intelligence is turned off.")
        case .modelNotReady: String(localized: "Apple Intelligence is getting ready. Try again in a few minutes.")
        case .languageNotSupported(let language): String(localized: "Apple Intelligence does not support \(language) yet.")
        }
    }

    /// A button to Apple Intelligence settings, only when the user can turn it on there.
    var settingsAction: DiagnosticAction? { self == .appleIntelligenceOff ? .openAppleIntelligenceSettings : nil }
}

/// What went wrong while the model wrote, reduced to what the interface says about it.
nonisolated enum AIFailure: Error, Equatable, Sendable {
    /// Too many requests, often while the app is in the background (a click on the widget).
    case rateLimited
    /// The conversation outgrew the model's context.
    case contextTooLong
    /// A guardrail or a refusal.
    case declined
    case unsupportedLanguage
    case notReady
    /// The text failed a check (`DiagnosticGuard.Rejection`).
    case rejected
    case cancelled
    case other

    /// Shown under a diagnostic written by the rules.
    var diagnosticMessage: String {
        switch self {
        case .rateLimited: String(localized: "Apple Intelligence is busy right now.")
        case .declined: String(localized: "Apple Intelligence declined to answer.")
        case .unsupportedLanguage: String(localized: "Apple Intelligence does not support this language yet.")
        case .notReady: String(localized: "Apple Intelligence is getting ready. Try again in a few minutes.")
        case .rejected: String(localized: "The AI text failed a check and was set aside.")
        case .contextTooLong, .cancelled, .other: String(localized: "Apple Intelligence could not answer.")
        }
    }

    /// Shown in place of an answer in the conversation.
    var answerMessage: String {
        switch self {
        case .declined: String(localized: "Apple Intelligence can't answer that. Try another question about your Mac.")
        case .contextTooLong: String(localized: "The conversation got too long. Start a new one.")
        case .rateLimited, .unsupportedLanguage, .notReady, .rejected, .cancelled, .other: diagnosticMessage
        }
    }
}

// MARK: - Language

/// The language the model writes in: the app's own, when the model speaks it.
nonisolated struct DiagnosticLanguage: Equatable, Sendable {
    /// Code of one of the app's localizations, like `fr` or `zh-Hans`.
    var code: String

    /// The language the app shows its interface in.
    static var app: DiagnosticLanguage { DiagnosticLanguage(code: Bundle.main.preferredLocalizations.first ?? "en") }

    var locale: Locale { Locale(identifier: code) }

    /// Its name in English, for the model's instructions ("French", "Chinese (Simplified)").
    var englishName: String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// Its name in itself, for the user ("français").
    var nativeName: String {
        locale.localizedString(forIdentifier: code) ?? code
    }
}

/// The diagnostic while the model writes it, before any check: for measures and tests, never shown.
nonisolated struct DiagnosticDraft: Equatable, Sendable {
    var verdict: DiagnosticVerdict?
    var explanation: String?
}

/// How long the model took, and what it cost.
nonisolated struct AITiming: Equatable, Sendable {
    /// Until the first piece of text.
    var firstText: TimeInterval?
    var total: TimeInterval
    /// Tokens, where the system says (macOS 27).
    var inputTokens: Int?
    var outputTokens: Int?
}
