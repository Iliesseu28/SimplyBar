import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Previews of the Diagnostic module (`--diagnostic`): the popup with its card and one question, the widget in both
/// sizes, and the popup when Apple Intelligence is off. Where Apple Intelligence runs, the card and the answer are
/// written by Apple's on-device model for a demo Mac, in the renderer's language, and checked as the app checks
/// them; elsewhere the rules write the card and no question is shown. Each image lies on a plain backdrop, about
/// 2000 pixels on its long side. The texts are printed, so a run says what the model wrote.
@MainActor
struct DiagnosticAssetRenderer {
    let renderer: AssetRenderer

    static let longSide: CGFloat = 2_000

    /// A demo number, `fallback` unless the command line gives `<flag> <value>` (to try what the model writes).
    static func demo(_ flag: String, _ fallback: Double) -> Double {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
            ?? fallback
    }

    /// A laptop at work: memory nearly full, the processor calm, so the card and the answer speak of memory only.
    /// Tried with Apple's model in French (`--cpu`, `--memory`, `--pressure`, `--swap` try other numbers): any
    /// processor load opened a "why is it slow" answer; a pressure above 0 came out as "câblées" or "filées"; a swap
    /// with decimals as "3.2 Go"; and some sets wrote "16 GB" on the card.
    var snapshot: MacSnapshot {
        let names = renderer.demo.names
        return MacSnapshot(
            date: DemoData.date, cpu: Int(Self.demo("--cpu", 25)), memoryUsed: Int(Self.demo("--memory", 92)),
            memoryPressure: Int(Self.demo("--pressure", 0)), memoryTotalGB: 16, swapGB: Self.demo("--swap", 3),
            disks: [
                .init(name: names.system, isStartup: true, freeGB: 182, totalGB: 494, freePercent: 37),
                .init(name: names.backup, isStartup: false, freeGB: 610, totalGB: 1_000, freePercent: 61),
            ],
            downloadMBps: 1.2, uploadMBps: 0.2, gpu: 18,
            devices: [.init(name: names.mouse, battery: 64), .init(name: names.keyboard, battery: 81)],
            thermal: .nominal,
            battery: .init(charge: 76, isCharging: false, maximumCapacity: 91, cycleCount: 212, serviceRecommended: false),
            uptimeHours: 30, keepAwake: false
        )
    }

    /// What the module shows for the demo Mac: the model's card and answer where it runs, the rules' card elsewhere.
    struct Content {
        let status: AIStatus
        let rules: DiagnosticReport
        let report: DiagnosticReport
        let messages: [DiagnosticMessage]
    }

    func content() -> Content {
        let language = DiagnosticLanguage.app
        let snapshot = snapshot
        let findings = DiagnosticRules.findings(snapshot)
        let rules = DiagnosticRules.report(snapshot, findings: findings, now: DemoData.date, locale: language.locale)
        var report = rules
        var messages: [DiagnosticMessage] = []
        let status = DiagnosticAIStatus.current(language: language)
        #if canImport(FoundationModels)
        if status == .available, #available(macOS 26, *) {
            // --rules-card keeps the rules' card, as the app does when the model's card fails its checks: in some
            // languages the model writes the card in English or half in English, while its answers are right.
            if !CommandLine.arguments.contains("--rules-card") {
                report = wait { await Self.write(snapshot: snapshot, findings: findings, rules: rules, language: language) }
            }
            // --no-question leaves the question out, where every answer the model gives mistranslates a fact.
            if !CommandLine.arguments.contains("--no-question") {
                messages = wait { await Self.question(snapshot: snapshot, language: language) }
            }
        }
        #endif
        print("status: \(status)")
        print("card (\(report.source.rawValue)): \(report.title) | \(report.explanation) | \(report.actions.map(\.rawValue))")
        for message in messages { print("\(message.role): \(message.text) \(message.actions.map(\.rawValue))") }
        return Content(status: status, rules: rules, report: report, messages: messages)
    }

    /// The Mac App Store set (`--store`): the popup and both widgets at the renderer's scale, on a transparent
    /// background like the other renderer images, so `compose_store.py` lays them out on its desktop.
    func renderStore() {
        let content = content()
        let monitor = SystemMonitor(settings: AppServices.settings)
        let popup = DiagnosticController(keepAwake: monitor.keepAwake)
        popup.status = content.status
        popup.card = DiagnosticCardState(report: content.report)
        popup.messages = content.messages
        renderer.save(DiagnosticPopup(monitor: monitor, diagnostic: popup), name: "popup-diagnostic")
        let state = DiagnosticWidgetState(report: content.report, isPending: false, date: DemoData.date)
        renderer.save(WidgetFrame(size: .small) { DiagnosticWidgetContent(state: state, isMedium: false) },
                      name: "widget-diagnostic-small")
        renderer.save(WidgetFrame(size: .medium) { DiagnosticWidgetContent(state: state, isMedium: true) },
                      name: "widget-diagnostic-medium")
    }

    func renderAll() {
        let content = content()
        let (status, rules, report, messages) = (content.status, content.rules, content.report, content.messages)

        let monitor = SystemMonitor(settings: AppServices.settings)
        let popup = DiagnosticController(keepAwake: monitor.keepAwake)
        popup.status = status
        popup.card = DiagnosticCardState(report: report)
        popup.messages = messages
        save(Self.panel(DiagnosticPopup(monitor: monitor, diagnostic: popup)), name: "apercu-diagnostic-popup")

        let state = DiagnosticWidgetState(report: report, isPending: false, date: DemoData.date)
        save(Self.backdrop(HStack(alignment: .top, spacing: 32) {
            Self.widget(.small) { DiagnosticWidgetContent(state: state, isMedium: false) }
            Self.widget(.medium) { DiagnosticWidgetContent(state: state, isMedium: true) }
        }), name: "apercu-diagnostic-widgets")

        let off = DiagnosticController(keepAwake: monitor.keepAwake)
        off.status = .appleIntelligenceOff
        off.card = DiagnosticCardState(report: rules)
        save(Self.panel(DiagnosticPopup(monitor: monitor, diagnostic: off)), name: "apercu-diagnostic-ia-desactivee")
    }

    #if canImport(FoundationModels)
    /// The card the app would show: the model's when it passes the checks, the rules' otherwise.
    @available(macOS 26, *)
    static func write(snapshot: MacSnapshot, findings: [DiagnosticFinding], rules: DiagnosticReport,
                      language: DiagnosticLanguage) async -> DiagnosticReport {
        let allowed = DiagnosticRules.allowedActions(findings: findings, snapshot: snapshot)
        do {
            let schema = try DiagnosticAI.diagnosisSchema(verdict: rules.verdict, allowed: allowed)
            let prompt = DiagnosticAI.diagnosticPrompt(snapshot: snapshot, findings: findings, allowed: allowed)
            let session = DiagnosticAI.makeDiagnosticSession(language: language)
            let (candidate, timing) = try await DiagnosticAI.diagnose(session: session, prompt: prompt, schema: schema) { _ in }
            print("model card first=\(timing.firstText ?? -1) total=\(timing.total)")
            let facts = DiagnosticGuard.referenceFacts(snapshot, findings: findings)
            switch DiagnosticGuard.validate(candidate, rules: rules, allowed: allowed, facts: facts, now: DemoData.date) {
            case .success(let report): return report
            case .failure(let rejection): print("model card set aside: \(rejection)")
            }
        } catch {
            print("model card failed: \(DiagnosticAI.failure(from: error))")
        }
        return rules
    }

    /// The first suggested question and the model's answer, with the buttons the app would keep.
    @available(macOS 26, *)
    static func question(snapshot: MacSnapshot, language: DiagnosticLanguage) async -> [DiagnosticMessage] {
        // The first suggested question, or the one typed after --question (what a user may type in the field).
        let arguments = CommandLine.arguments
        let typed = arguments.firstIndex(of: "--question").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let question = typed ?? String(localized: DiagnosticController.suggestedQuestions[0])
        let conversation = DiagnosticConversation(language: language, snapshot: { snapshot })
        do {
            let answer = try await conversation.ask(question) { _ in }
            print("model answer tools=\(answer.toolCalls) first=\(answer.timing.firstText ?? -1) total=\(answer.timing.total)")
            let actions = DiagnosticGuard.answerActions(answer.actions, toolCalls: answer.toolCalls, snapshot: snapshot)
            return [DiagnosticMessage(role: .question, text: question),
                    DiagnosticMessage(role: .answer, text: DiagnosticGuard.display(answer.text), actions: actions)]
        } catch {
            print("model answer failed: \(DiagnosticAI.failure(from: error))")
            return []
        }
    }
    #endif

    // MARK: - Drawing

    /// Runs the model while the run loop turns, as the views need it to.
    private func wait<T>(_ operation: @escaping @MainActor () async -> T) -> T {
        let box = ResultBox<T>()
        Task { @MainActor in box.value = await operation() }
        let deadline = Date().addingTimeInterval(120)
        while box.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let value = box.value else { ScreenshotRenderer.fail("Apple's model did not answer within 2 minutes") }
        return value
    }

    /// Draws a view so that its long side is `longSide` pixels.
    private func save<V: View>(_ view: V, name: String) {
        let size = NSHostingView(rootView: view.environment(\.colorScheme, .light)).fittingSize
        let scale = Self.longSide / max(size.width, size.height, 1)
        let scaled = AssetRenderer(output: renderer.output, scale: scale, rtl: renderer.rtl, demo: renderer.demo)
        guard let image = scaled.capture(AnyView(view), mirrored: true, prepare: {}) else {
            ScreenshotRenderer.fail("nothing drawn for \(name)")
        }
        renderer.write(image, name: name)
    }

    /// A popup in the window the menu bar gives it.
    private static func panel<V: View>(_ popup: V) -> some View {
        backdrop(popup
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)))
    }

    private static func widget<V: View>(_ size: WidgetFrame<V>.Size, @ViewBuilder _ content: () -> V) -> some View {
        let built = content()
        return WidgetFrame(size: size) { built }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                .shadow(color: .black.opacity(0.14), radius: 10, y: 3))
    }

    private static func backdrop<V: View>(_ content: V) -> some View {
        content
            .padding(40)
            .background(LinearGradient(colors: [Color(red: 0.85, green: 0.90, blue: 0.98), Color(red: 0.94, green: 0.89, blue: 0.97)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor
private final class ResultBox<T> {
    var value: T?
}
