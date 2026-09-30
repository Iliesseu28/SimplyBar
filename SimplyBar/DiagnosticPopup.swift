import SwiftUI

struct DiagnosticPopup: View {
    let monitor: SystemMonitor
    let diagnostic: DiagnosticController

    var body: some View {
        PopupChrome(module: .diagnostic, title: "Diagnostic", monitor: monitor, width: 340) {
            DiagnosticContent(diagnostic: diagnostic)
        }
    }
}

/// The popup without its frame, also drawn by the screenshot renderer.
struct DiagnosticContent: View {
    let diagnostic: DiagnosticController
    @State private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            card
            if let message = diagnostic.status.message ?? diagnostic.card.failure?.diagnosticMessage {
                AIStatusNote(message: message, action: diagnostic.status.settingsAction, perform: diagnostic.perform)
            }
            Divider()
            conversation
            // Only when the model wrote something shown: the card or an answer.
            if diagnostic.card.report?.source == .ai || diagnostic.messages.contains(where: { $0.role == .answer }) {
                Text("Written on this Mac by Apple's on-device AI. Nothing leaves your Mac.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The model's text shows only once checked: while it writes, the rules' verdict and "Analyzing".
    @ViewBuilder private var card: some View {
        switch diagnostic.card.display {
        case .report(let report):
            DiagnosticCard(verdict: report.verdict, title: report.title, explanation: report.explanation,
                           actions: report.actions, perform: diagnostic.perform)
        case .analyzing(let verdict):
            VStack(alignment: .leading, spacing: 8) {
                if let verdict {
                    HStack(spacing: 6) {
                        Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
                        Text(verdict.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(verdict.color)
                    }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Group {
                        if verdict == nil { Text("Checking your Mac…") } else { Text("Analyzing…") }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background((verdict?.color ?? .secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var conversation: some View {
        HStack {
            SectionTitle("Ask a question")
            Spacer()
            if !diagnostic.messages.isEmpty {
                Button {
                    diagnostic.resetConversation()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("New conversation"))
            }
        }
        if diagnostic.status == .available {
            if diagnostic.messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(DiagnosticController.suggestedQuestions, id: \.key) { suggestion in
                        Button {
                            diagnostic.ask(String(localized: suggestion))
                        } label: {
                            Label { Text(suggestion) } icon: { Image(systemName: "text.bubble") }
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .disabled(diagnostic.isBusy)
                    }
                }
            } else {
                DiagnosticMessages(messages: diagnostic.messages, isAnswering: diagnostic.isAnswering,
                                   perform: diagnostic.perform)
            }
            HStack(spacing: 6) {
                TextField("Ask about your Mac", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .onChange(of: question) {
                        if question.count > DiagnosticGuard.maximumQuestionLength {
                            question = String(question.prefix(DiagnosticGuard.maximumQuestionLength))
                        }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || diagnostic.isBusy)
                .help(Text("Send"))
            }
        } else {
            Text("Questions need Apple Intelligence. The diagnostic above works without it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send() {
        guard !diagnostic.isBusy else { return }
        diagnostic.ask(question)
        question = ""
    }
}

/// Verdict, title, two sentences and up to three buttons.
struct DiagnosticCard: View {
    let verdict: DiagnosticVerdict
    let title: String
    let explanation: String
    let actions: [DiagnosticAction]
    let perform: (DiagnosticAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: verdict.symbol).foregroundStyle(verdict.color)
                Text(verdict.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(verdict.color)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !explanation.isEmpty {
                Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !actions.isEmpty {
                ActionButtons(actions: actions, perform: perform)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdict.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ActionButtons: View {
    let actions: [DiagnosticAction]
    let perform: (DiagnosticAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(actions) { action in
                Button {
                    perform(action)
                } label: {
                    Label { Text(action.title) } icon: { Image(systemName: action.symbol) }
                        .font(.system(size: 12))
                }
                .controlSize(.small)
            }
        }
    }
}

/// Why the rules wrote the card, with Apple Intelligence settings when it is turned off.
struct AIStatusNote: View {
    let message: String
    let action: DiagnosticAction?
    let perform: (DiagnosticAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(message) } icon: { Image(systemName: "sparkles") }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button {
                    perform(action)
                } label: {
                    Text(action.title).font(.system(size: 11))
                }
                .controlSize(.small)
            }
        }
    }
}

struct DiagnosticMessages: View {
    let messages: [DiagnosticMessage]
    /// The answer shows once whole and checked; until then, a spinner.
    let isAnswering: Bool
    let perform: (DiagnosticAction) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        bubble(message)
                    }
                    if isAnswering {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("answering")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: messages.count) { proxy.scrollTo(messages.last?.id) }
            .onChange(of: isAnswering) { if isAnswering { proxy.scrollTo("answering") } }
        }
    }

    @ViewBuilder private func bubble(_ message: DiagnosticMessage) -> some View {
        switch message.role {
        case .question:
            Text(message.text).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .id(message.id)
        case .answer:
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.actions.isEmpty { ActionButtons(actions: message.actions, perform: perform) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(message.id)
        case .notice:
            Text(message.text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id(message.id)
        }
    }
}
