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

/// The Diagnostic module: the card, written by the rules and by Apple's on-device model where it can, the
/// conversation, and the diagnostic the widget asks for. One model request at a time: a diagnostic waits for the
/// answer being written, and no question is taken while a diagnostic or an answer runs. Nothing of the model is
/// shown before its checks. Closing the popup cancels the popup's own requests. Nothing leaves the Mac: the model
/// runs on it, and the app has no network access.
@MainActor
@Observable
final class DiagnosticController {
    nonisolated static let log = Logger(subsystem: "fr.simplibot.simplybar", category: "diagnostic")

    static let suggestedQuestions: [LocalizedStringResource] = [
        "Why is my Mac slow?", "How much space is left on my disk?", "Is my Mac too hot?",
    ]

    /// The card: the model's once checked, the rules' otherwise, "Analyzing" while the model writes.
    private(set) var card = DiagnosticCardState()
    /// A diagnostic runs, the popup's or the widget's.
    private(set) var isRunning = false
    /// A question is being answered: set when it is asked, cleared when its task ends.
    private(set) var isAnswering = false
    private(set) var status: AIStatus = .systemTooOld
    private(set) var messages: [DiagnosticMessage] = []
    /// Date of the last widget request answered in the payload: the widget stops waiting for it.
    private(set) var handledRequest: Date?

    @ObservationIgnored let source: SnapshotSource
    @ObservationIgnored private let keepAwake: KeepAwakeController
    @ObservationIgnored private var cache: DiagnosticCache?
    @ObservationIgnored private var runTask: Task<Void, Never>?
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

    /// The card for the widget: never a text of the model before its checks.
    var report: DiagnosticReport? { card.report }
    /// The model is at work: no new question until it is done.
    var isBusy: Bool { isRunning || isAnswering }
    private var language: DiagnosticLanguage { .app }

    // MARK: - Popup

    func popupOpened() {
        status = DiagnosticAIStatus.current(language: language)
        #if canImport(FoundationModels)
        // For the questions; it also loads the model while the Mac is measured.
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

    /// Runs a diagnostic, or waits for the one running. A cancelled one is never waited for: a new one starts
    /// once it has stopped.
    func run() async {
        if let runTask, !runTask.isCancelled { return await runTask.value }
        let previous = runTask
        let task = Task {
            await previous?.value
            await diagnose()
        }
        runTask = task
        isRunning = true
        await task.value
        if runTask == task {
            runTask = nil
            isRunning = false
        }
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

    private func diagnose() async {
        let start = Date.now
        let language = language
        status = DiagnosticAIStatus.current(language: language)
        let snapshot = await source.current(fresh: true)
        var write: DiagnosticPipeline.Writer?
        #if canImport(FoundationModels)
        if status == .available, #available(macOS 26, *) {
            write = { [self] findings, rules in
                card.startWriting(verdict: rules.verdict)
                // One model request at a time: an answer being written ends first.
                await askTask?.value
                return await self.write(snapshot: snapshot, findings: findings, rules: rules, language: language)
            }
        }
        #endif
        let outcome = await DiagnosticPipeline.run(snapshot: snapshot, cache: cache, locale: language.locale, write: write)
        card.finish(outcome)
        let result: DiagnosticReport
        switch outcome {
        case .cancelled:
            Self.log.notice("Diagnostic cancelled: the card stays as it was")
            return
        case .reused(let report):
            Self.log.notice("Diagnostic reused: nothing changed notably since the last one")
            result = report
        case .written(let report):
            cache = DiagnosticCache(snapshot: snapshot, findings: DiagnosticRules.findings(snapshot), report: report)
            result = report
        case .rules(let report, _):
            result = report
        }
        let duration = Date.now.timeIntervalSince(start)
        Self.log.notice("""
            Diagnostic done source=\(result.source.rawValue, privacy: .public) \
            verdict=\(result.verdict.rawValue, privacy: .public) status=\(String(describing: self.status), privacy: .public) \
            failure=\(self.card.failure.map { String(describing: $0) } ?? "none", privacy: .public) \
            seconds=\(duration, format: .fixed(precision: 2), privacy: .public)
            """)
    }

    #if canImport(FoundationModels)
    /// The model's card, checked by `DiagnosticGuard`, or why the rules' card stays. Its session is made here, once
    /// the cache had nothing: a new one for each diagnostic.
    @available(macOS 26, *)
    private func write(snapshot: MacSnapshot, findings: [DiagnosticFinding], rules: DiagnosticReport,
                       language: DiagnosticLanguage) async -> Result<DiagnosticReport, AIFailure> {
        let allowed = DiagnosticRules.allowedActions(findings: findings, snapshot: snapshot)
        do {
            let schema = try DiagnosticAI.diagnosisSchema(verdict: rules.verdict, allowed: allowed)
            let prompt = DiagnosticAI.diagnosticPrompt(snapshot: snapshot, findings: findings, allowed: allowed)
            let session = DiagnosticAI.makeDiagnosticSession(language: language)
            // The drafts are not shown: the card changes only once the text passed its checks.
            let (candidate, timing) = try await DiagnosticAI.diagnose(session: session, prompt: prompt, schema: schema) { _ in }
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
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DiagnosticGuard.maximumQuestionLength))
        guard !question.isEmpty, !isBusy else { return }
        let asked = DiagnosticMessage(role: .question, text: question)
        messages.append(asked)
        isAnswering = true
        askTask = Task {
            await answer(question, asked: asked.id)
            askTask = nil
            isAnswering = false
        }
    }

    /// Adds the answer once whole and checked, or a note: nothing of the model shows before its checks.
    private func answer(_ question: String, asked: UUID) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), let conversation = currentConversation() {
            do {
                let answer = try await conversation.ask(question) { _ in }
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
                if failure == .cancelled || Task.isCancelled {
                    // The popup closed: the question stays, marked. After a reset it is gone, and so is the note.
                    if messages.contains(where: { $0.id == asked }) {
                        messages.append(DiagnosticMessage(role: .notice, text: String(localized: "Answer interrupted. Ask the question again.")))
                    }
                    return
                }
                let reason = (error as? DiagnosticGuard.Rejection)?.rawValue ?? String(describing: failure)
                Self.log.notice("Answer set aside: \(reason, privacy: .public)")
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
