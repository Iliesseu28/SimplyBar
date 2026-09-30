import Foundation

#if canImport(FoundationModels)

/// Questions that each need one tool, for the evaluation of "Ask a question" with the real model.
enum DiagnosticQuestions {
    struct Question: Sendable {
        var name: String
        var english: String
        var french: String
        var tool: SnapshotDomain
        /// A number the answer must give, read from the snapshot; nil when a word is enough ("on", "normal").
        var expected: (@Sendable (MacSnapshot) -> Double?)?

        func text(_ language: String) -> String { language == "fr" ? french : english }
    }

    /// A Mac with a number to find for each question.
    static let snapshot = DiagnosticScenarios.changed {
        $0.disks[0] = .init(name: "Macintosh HD", isStartup: true, freeGB: 4.2, totalGB: 245, freePercent: 2)
        $0.devices[0].battery = 8
        $0.downloadMBps = 85
        $0.cpu = 64
        $0.gpu = 37
        $0.memoryUsed = 81
    }

    static let all: [Question] = [
        Question(name: "startupDisk", english: "How much free space is left on my startup disk?",
                 french: "Combien d'espace libre reste-t-il sur mon disque de démarrage ?",
                 tool: .disks, expected: { $0.startupDisk?.freeGB }),
        Question(name: "processor", english: "How busy is my processor right now?",
                 french: "À combien est occupé mon processeur en ce moment ?", tool: .cpu, expected: { $0.cpu.map(Double.init) }),
        Question(name: "memory", english: "How much of my memory is used?",
                 french: "Quelle part de ma mémoire est utilisée ?", tool: .memory, expected: { $0.memoryUsed.map(Double.init) }),
        Question(name: "mouse", english: "What is the battery level of my mouse?",
                 french: "Quel est le niveau de batterie de ma souris ?", tool: .bluetooth,
                 expected: { $0.devices.first?.battery.map(Double.init) }),
        Question(name: "download", english: "How fast am I downloading right now?",
                 french: "À quelle vitesse je télécharge en ce moment ?", tool: .network, expected: { $0.downloadMBps }),
        Question(name: "graphics", english: "How busy is my graphics processor?",
                 french: "À combien est occupée ma carte graphique ?", tool: .gpu, expected: { $0.gpu.map(Double.init) }),
        Question(name: "heat", english: "Is my Mac too hot?", french: "Mon Mac chauffe-t-il trop ?", tool: .health, expected: nil),
        Question(name: "keepAwake", english: "Is Keep Awake on?", french: "L'anti-veille est-elle activée ?",
                 tool: .keepAwake, expected: nil),
    ]

    struct Check: Sendable {
        var toolCalled = false
        var numberFound = true
        var found: [Double] = []
        var languageMatches = false
        var passed: Bool { toolCalled && numberFound && languageMatches }
    }

    /// The right tool was called (seen in the transcript) and the answer gives its number.
    @available(macOS 26, *)
    static func check(_ answer: DiagnosticConversation.Answer, question: Question, snapshot: MacSnapshot,
                      language: String) -> Check {
        var check = Check()
        check.languageMatches = DiagnosticGuard.language(of: answer.text) == language
        check.toolCalled = answer.toolCalls.contains(question.tool.rawValue)
        check.found = DiagnosticGuard.numbers(in: answer.text)
        if let expected = question.expected?(snapshot) {
            check.numberFound = check.found.contains { abs($0 - expected) < 0.05 || $0 == expected.rounded() }
        }
        return check
    }
}

#endif
