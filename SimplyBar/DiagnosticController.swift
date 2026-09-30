import AppKit
import Observation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A line of the "Ask a question" conversation.
struct DiagnosticMessage: Identifiable, Equatable {
    enum Role { case question, answer, notice }

    let id = UUID()
    var role: Role
    var text: String
    var actions: [DiagnosticAction] = []
}

/// The Diagnostic module: the card, written by the rules and rewritten by Apple's on-device model where it can, the
/// conversation, and the diagnostic the widget asks for. One model request at a time; closing the popup cancels
/// the popup's own requests. Nothing leaves the Mac: the model runs on it, and the app has no network access.
@MainActor
@Observable
final class DiagnosticController {
    nonisolated static let log = Logger(subsystem: "fr.simplibot.simplybar", category: "diagnostic")

    static let suggestedQuestions: [LocalizedStringResource] = [
        "Why is my Mac slow?", "How much space is left on my disk?", "Is my Mac too hot?",
    ]

    /// The card shown: the model's, or the rules' when the model cannot or its text failed a check.
    private(set) var report: DiagnosticReport?
    /// The card while the model writes it.
    private(set) var draft: DiagnosticDraft?
    private(set) var isRunning = false
    private(set) var status: AIStatus = .systemTooOld
    /// Why the card comes from the rules although the model is there.
    private(set) var failure: AIFailure?
    private(set) var messages: [DiagnosticMessage] = []
    /// The answer being written, shown under the last question.
    private(set) var partialAnswer: String?
    /// Date of the last widget request answered in the payload: the widget stops waiting for it.
    private(set) var handledRequest: Date?

    @ObservationIgnored let source: SnapshotSource
    @ObservationIgnored private let keepAwake: KeepAwakeController
    @ObservationIgnored private var cache: DiagnosticCache?
    @ObservationIgnored private var runTask: Task<DiagnosticReport, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    /// The `DiagnosticConversation` (macOS 26), kept while the app runs; the reset button starts it over.
    @ObservationIgnored private var conversation: AnyObject?
    @ObservationIgnored private var widgetRequestsRunning = 0
    /// Told when a diagnostic ends, so the widget can show it.
    @ObservationIgnored var onChange: (() -> Void)?

    init(keepAwake: KeepAwakeController) {
        self.keepAwake = keepAwake
        source = SnapshotSource { [weak keepAwake] in keepAwake?.isActive ?? false }
    }

    var isAnswering: Bool { askTask != nil }
    private var language: DiagnosticLanguage { .app }

    // MARK: - Popup

    func popupOpened() {
        status = DiagnosticAIStatus.current(language: language)
        #if canImport(FoundationModels)
        if status == .available, #available(macOS 26, *) { currentConversation()?.prewarm() }
        #endif
        Task { await run() }
    }

    /// Stops what the popup asked for; a diagnostic the widget waits for goes on.
    func popupClosed() {
        askTask?.cancel()
        if widgetRequestsRunning == 0 { runTask?.cancel() }
    }

    // MARK: - Diagnostic

    /// Runs a diagnostic, or waits for the one running.
    @discardableResult
    func run() async -> DiagnosticReport {
        if let runTask { return await runTask.value }
        let task = Task { await diagnose() }
        runTask = task
        let report = await task.value
        runTask = nil
        return report
    }

    func widgetRequested(_ request: DiagnosticRequest) {
        widgetRequestsRunning += 1
        Task {
            await run()
            widgetRequestsRunning -= 1
            handledRequest = request.date
            onChange?()
        }
    }

    private func diagnose() async -> DiagnosticReport {
        isRunning = true
        defer {
            isRunning = false
            draft = nil
        }
        let start = Date.now
        let language = language
        status = DiagnosticAIStatus.current(language: language)
        #if canImport(FoundationModels)
        // Created before the Mac is measured, so the model loads during that second.
        var session: AnyObject?
        if status == .available, #available(macOS 26, *) {
            let diagnosticSession = DiagnosticAI.makeDiagnosticSession(language: language)
            diagnosticSession.prewarm()
            session = diagnosticSession
        }
        #endif
        let snapshot = await source.current(fresh: true)
        let findings = DiagnosticRules.findings(snapshot)
        let rules = DiagnosticRules.report(snapshot, findings: findings, locale: language.locale)
        failure = nil
        var result = rules
        if let cached = cache?.reusable(for: snapshot, findings: findings, now: .now) {
            result = cached
            Self.log.notice("Diagnostic reused: nothing changed notably since the last one")
        } else {
            if report?.source != .ai { report = rules }
            #if canImport(FoundationModels)
            if #available(macOS 26, *), let session = session as? LanguageModelSession, !Task.isCancelled {
                switch await write(session: session, snapshot: snapshot, findings: findings, rules: rules) {
                case .success(let written):
                    result = written
                    cache = DiagnosticCache(snapshot: snapshot, findings: findings, report: written)
                case .failure(let reason):
                    failure = reason
                }
            }
            #endif
        }
        report = result
        let duration = Date.now.timeIntervalSince(start)
        Self.log.notice("""
            Diagnostic done source=\(result.source.rawValue, privacy: .public) \
            verdict=\(result.verdict.rawValue, privacy: .public) status=\(String(describing: self.status), privacy: .public) \
            failure=\(self.failure.map { String(describing: $0) } ?? "none", privacy: .public) \
            seconds=\(duration, format: .fixed(precision: 2), privacy: .public)
            """)
        return result
    }

    #if canImport(FoundationModels)
    /// The model's card, checked by `DiagnosticGuard`, or why the rules' card stays.
    @available(macOS 26, *)
    private func write(session: LanguageModelSession, snapshot: MacSnapshot, findings: [DiagnosticFinding],
                       rules: DiagnosticReport) async -> Result<DiagnosticReport, AIFailure> {
        let allowed = DiagnosticRules.allowedActions(findings: findings, snapshot: snapshot)
        do {
            let schema = try DiagnosticAI.diagnosisSchema(verdict: rules.verdict, allowed: allowed)
            let prompt = DiagnosticAI.diagnosticPrompt(snapshot: snapshot, findings: findings, allowed: allowed)
            let (candidate, timing) = try await DiagnosticAI.diagnose(session: session, prompt: prompt, schema: schema) {
                draft = $0
            }
            Self.log.notice("""
                Model wrote the diagnostic first=\(timing.firstText ?? -1, format: .fixed(precision: 2), privacy: .public) \
                total=\(timing.total, format: .fixed(precision: 2), privacy: .public) \
                tokens=\(timing.inputTokens ?? -1, privacy: .public)/\(timing.outputTokens ?? -1, privacy: .public)
                """)
            let facts = DiagnosticGuard.referenceFacts(snapshot, findings: findings)
            switch DiagnosticGuard.validate(candidate, rules: rules, allowed: allowed, facts: facts) {
            case .success(let report):
                return .success(report)
            case .failure(let rejection):
                Self.log.notice("Model diagnostic set aside: \(rejection.rawValue, privacy: .public)")
                return .failure(.rejected)
            }
        } catch {
            let failure = DiagnosticAI.failure(from: error)
            Self.log.notice("Model diagnostic failed: \(String(describing: failure), privacy: .public)")
            return .failure(failure)
        }
    }
    #endif

    // MARK: - Conversation

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private func currentConversation() -> DiagnosticConversation? {
        guard status == .available else { return nil }
        if let conversation = conversation as? DiagnosticConversation { return conversation }
        let source = source
        let conversation = DiagnosticConversation(language: language, snapshot: { await source.current() }) { domain in
            DiagnosticController.log.notice("Tool called: \(domain.rawValue, privacy: .public)")
        }
        self.conversation = conversation
        return conversation
    }
    #endif

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, askTask == nil else { return }
        messages.append(DiagnosticMessage(role: .question, text: question))
        askTask = Task {
            defer {
                partialAnswer = nil
                askTask = nil
            }
            await answer(question)
        }
    }

    private func answer(_ question: String) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let conversation = currentConversation() {
            do {
                let answer = try await conversation.ask(question) { partialAnswer = DiagnosticGuard.display($0) }
                if answer.restarted {
                    messages.append(DiagnosticMessage(role: .notice, text: String(localized: "The conversation was too long and started over.")))
                }
                let snapshot = await source.current()
                let actions = DiagnosticGuard.answerActions(answer.actions, toolCalls: answer.toolCalls, snapshot: snapshot)
                messages.append(DiagnosticMessage(role: .answer, text: DiagnosticGuard.display(answer.text), actions: actions))
                Self.log.notice("""
                    Answer written tools=\(answer.toolCalls.joined(separator: ","), privacy: .public) \
                    translated=\(answer.translated, privacy: .public) \
                    first=\(answer.timing.firstText ?? -1, format: .fixed(precision: 2), privacy: .public) \
                    total=\(answer.timing.total, format: .fixed(precision: 2), privacy: .public)
                    """)
            } catch {
                let failure = DiagnosticAI.failure(from: error)
                guard failure != .cancelled else { return }
                Self.log.notice("Answer failed: \(String(describing: failure), privacy: .public)")
                messages.append(DiagnosticMessage(role: .notice, text: failure.answerMessage))
            }
            return
        }
        #endif
        messages.append(DiagnosticMessage(role: .notice, text: status.message ?? AIFailure.other.answerMessage))
    }

    /// A new conversation: the model forgets the previous questions.
    func resetConversation() {
        askTask?.cancel()
        messages = []
        partialAnswer = nil
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { (conversation as? DiagnosticConversation)?.reset() }
        #endif
    }

    // MARK: - Buttons

    /// Runs a button of the card or of an answer: only here, on the owner's click, never by the model.
    func perform(_ action: DiagnosticAction) {
        Self.log.notice("Diagnostic button: \(action.rawValue, privacy: .public)")
        switch action {
        case .openActivityMonitor:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .openStorageSettings:
            openSettingsPane("com.apple.settings.Storage")
        case .openBatterySettings:
            openSettingsPane("com.apple.Battery-Settings.extension")
        case .openAppleIntelligenceSettings:
            openSettingsPane("com.apple.Siri-Settings.extension")
        case .keepAwakeOneHour:
            keepAwake.start(for: .oneHour)
        case .openAlerts:
            SettingsWindowController.shared.show(tab: .alerts)
        }
    }

    /// A pane of System Settings, by the identifier of its extension.
    private func openSettingsPane(_ identifier: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(identifier)") else { return }
        NSWorkspace.shared.open(url)
    }
}
