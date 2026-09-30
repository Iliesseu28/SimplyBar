import Foundation

/// Something the rules found in a snapshot.
nonisolated struct DiagnosticFinding: Equatable, Sendable {
    /// In the order a tie of severity is shown: what hurts the Mac first.
    enum Kind: String, CaseIterable, Sendable {
        case heat, startupDisk, memory, battery, disk, bluetooth, cpu, gpu, batteryHealth, network, uptime
    }

    enum Severity: Int, Comparable, Sendable {
        /// Worth a word, not a worry: the verdict stays OK.
        case info, watch, problem

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var verdict: DiagnosticVerdict {
            switch self {
            case .info: .ok
            case .watch: .watch
            case .problem: .problem
            }
        }
    }

    var kind: Kind
    var severity: Severity
    /// The disk or device concerned, as typed by the user.
    var subject: String?

    /// Most severe first, then in the order of `Kind`.
    static func sorted(_ findings: [DiagnosticFinding]) -> [DiagnosticFinding] {
        findings.sorted {
            $0.severity != $1.severity
                ? $0.severity > $1.severity
                : Kind.allCases.firstIndex(of: $0.kind)! < Kind.allCases.firstIndex(of: $1.kind)!
        }
    }
}

/// Fixed thresholds that judge a snapshot, and the diagnostic they write on their own. The model never judges a
/// threshold: it gets these findings and rewrites them. The rules text is the fallback wherever the model is not
/// there (Intel Mac, macOS 14 or 15, Apple Intelligence off, a language it does not speak, an error), so the
/// Diagnostic module works on every Mac, in every language of the app.
nonisolated enum DiagnosticRules {
    static let cpuBusy = 85
    static let gpuBusy = 90
    /// Memory in use from this share up is short, and with this much swap it hurts.
    static let memoryFull = 90
    static let memoryPressureHigh = 50
    static let swapHigh = 4.0
    /// Startup disk: free share and free gigabytes under which it is almost full, then full.
    static let startupDiskLow = (share: 10, gigabytes: 15.0)
    static let startupDiskFull = (share: 5, gigabytes: 5.0)
    static let otherDiskFull = 5
    /// Same level as the Bluetooth alert.
    static let bluetoothLow = AlertRules.bluetoothLow
    static let bluetoothEmpty = 5
    static let batteryLow = 20
    static let batteryEmpty = 10
    static let batteryWorn = 80
    static let networkBusyMBps = (download: 20.0, upload: 10.0)
    static let longUptimeDays = 14

    static func findings(_ snapshot: MacSnapshot) -> [DiagnosticFinding] {
        var found: [DiagnosticFinding] = []
        func add(_ kind: DiagnosticFinding.Kind, _ severity: DiagnosticFinding.Severity, _ subject: String? = nil) {
            found.append(DiagnosticFinding(kind: kind, severity: severity, subject: subject))
        }
        switch snapshot.thermal {
        case .critical?: add(.heat, .problem)
        case .serious?: add(.heat, .watch)
        case .fair?: add(.heat, .info)
        case .nominal?, nil: break
        }
        if let disk = snapshot.startupDisk {
            if disk.freePercent < startupDiskFull.share || disk.freeGB < startupDiskFull.gigabytes {
                add(.startupDisk, .problem, disk.name)
            } else if disk.freePercent < startupDiskLow.share || disk.freeGB < startupDiskLow.gigabytes {
                add(.startupDisk, .watch, disk.name)
            }
        }
        for disk in snapshot.disks where !disk.isStartup && disk.freePercent < otherDiskFull {
            add(.disk, .watch, disk.name)
        }
        if let used = snapshot.memoryUsed {
            let swap = snapshot.swapGB ?? 0
            if used >= memoryFull, swap >= swapHigh {
                add(.memory, .problem)
            } else if used >= memoryFull || swap >= swapHigh || (snapshot.memoryPressure ?? 0) >= memoryPressureHigh {
                add(.memory, .watch)
            }
        }
        if let battery = snapshot.battery {
            if !battery.isCharging, battery.charge <= batteryEmpty {
                add(.battery, .problem)
            } else if !battery.isCharging, battery.charge <= batteryLow {
                add(.battery, .watch)
            }
            if battery.serviceRecommended || (battery.maximumCapacity ?? 100) < batteryWorn {
                add(.batteryHealth, .watch)
            }
        }
        for device in snapshot.devices {
            guard let level = device.battery else { continue }
            if level <= bluetoothEmpty {
                add(.bluetooth, .problem, device.name)
            } else if level <= bluetoothLow {
                add(.bluetooth, .watch, device.name)
            }
        }
        if let cpu = snapshot.cpu, cpu >= cpuBusy { add(.cpu, .watch) }
        if let gpu = snapshot.gpu, gpu >= gpuBusy { add(.gpu, .watch) }
        if (snapshot.downloadMBps ?? 0) >= networkBusyMBps.download || (snapshot.uploadMBps ?? 0) >= networkBusyMBps.upload {
            add(.network, .info)
        }
        if let hours = snapshot.uptimeHours, hours / 24 >= longUptimeDays { add(.uptime, .info) }
        return DiagnosticFinding.sorted(found)
    }

    static func verdict(_ findings: [DiagnosticFinding]) -> DiagnosticVerdict {
        findings.map(\.severity.verdict).max() ?? .ok
    }

    // MARK: - Actions

    /// Whether a button makes sense for these findings: no "free up space" while the disk is fine. The model's
    /// buttons are checked against it too.
    static func allows(_ action: DiagnosticAction, findings: [DiagnosticFinding], snapshot: MacSnapshot) -> Bool {
        func has(_ kinds: Set<DiagnosticFinding.Kind>, from severity: DiagnosticFinding.Severity = .watch) -> Bool {
            findings.contains { kinds.contains($0.kind) && $0.severity >= severity }
        }
        switch action {
        case .openActivityMonitor: return has([.cpu, .gpu, .memory, .heat]) || has([.network], from: .info)
        case .openStorageSettings: return has([.startupDisk])
        case .openBatterySettings: return has([.battery, .batteryHealth])
        case .keepAwakeOneHour: return !snapshot.keepAwake && has([.network], from: .info)
        case .openAlerts: return has([.startupDisk, .bluetooth, .heat])
        // Offered by the app when Apple Intelligence is off, never as a diagnostic button.
        case .openAppleIntelligenceSettings: return false
        }
    }

    /// The buttons the model may offer for this snapshot.
    static func allowedActions(findings: [DiagnosticFinding], snapshot: MacSnapshot) -> [DiagnosticAction] {
        DiagnosticAction.allCases.filter { allows($0, findings: findings, snapshot: snapshot) }
    }

    /// The buttons of a finding, most useful first.
    private static func actions(for kind: DiagnosticFinding.Kind) -> [DiagnosticAction] {
        switch kind {
        case .heat, .cpu, .gpu, .memory: [.openActivityMonitor, .openAlerts]
        case .startupDisk: [.openStorageSettings, .openAlerts]
        case .disk: []
        case .battery, .batteryHealth: [.openBatterySettings]
        case .bluetooth: [.openAlerts]
        case .network: [.keepAwakeOneHour, .openActivityMonitor]
        case .uptime: []
        }
    }

    // MARK: - Text

    /// The diagnostic the rules write on their own, in the language of the app.
    static func report(_ snapshot: MacSnapshot, findings: [DiagnosticFinding], now: Date = .now,
                       locale: Locale = .current) -> DiagnosticReport {
        let concerns = findings.filter { $0.severity >= .watch }
        var actions: [DiagnosticAction] = []
        for finding in concerns.isEmpty ? findings : concerns {
            for action in Self.actions(for: finding.kind)
            where !actions.contains(action) && allows(action, findings: findings, snapshot: snapshot) {
                actions.append(action)
            }
        }
        actions = Array(actions.prefix(DiagnosticReport.maximumActions))
        guard let top = concerns.first else {
            let note = findings.first.flatMap { note($0, snapshot: snapshot, locale: locale) }
                ?? String(localized: "Nothing needs your attention right now.")
            return DiagnosticReport(
                verdict: .ok, title: String(localized: "Your Mac is doing fine"),
                explanation: String(localized: "Processor, memory, disks and heat are within normal limits.") + " " + note,
                actions: actions, source: .rules, date: now
            )
        }
        let topTopic = String(localized: top.kind.topic)
        let others = concerns.dropFirst().map { String(localized: $0.kind.topic) }.reduce(into: [String]()) {
            if !$0.contains($1) && $1 != topTopic { $0.append($1) }
        }
        let second = others.isEmpty
            ? advice(top, snapshot: snapshot)
            : String(localized: "Also worth checking: \(others.formatted(.list(type: .and).locale(locale))).")
        return DiagnosticReport(
            verdict: verdict(findings), title: title(top),
            explanation: [detail(top, snapshot: snapshot, locale: locale), second].filter { !$0.isEmpty }.joined(separator: " "),
            actions: actions, source: .rules, date: now
        )
    }

    private static func title(_ finding: DiagnosticFinding) -> String {
        switch finding.kind {
        case .heat: finding.severity == .problem ? String(localized: "Your Mac is very hot") : String(localized: "Your Mac is hot")
        case .startupDisk: String(localized: "Startup disk almost full")
        case .disk: String(localized: "A disk is almost full")
        case .memory: String(localized: "Memory is running short")
        case .battery: String(localized: "Battery low")
        case .batteryHealth: String(localized: "Battery wearing out")
        case .bluetooth: String(localized: "Bluetooth battery low")
        case .cpu: String(localized: "Processor very busy")
        case .gpu: String(localized: "Graphics very busy")
        case .network: String(localized: "Network very busy")
        case .uptime: String(localized: "Your Mac is doing fine")
        }
    }

    /// First sentence: what the numbers say.
    private static func detail(_ finding: DiagnosticFinding, snapshot: MacSnapshot, locale: Locale) -> String {
        func percent(_ value: Int) -> String { Format.percent(Double(value) / 100, locale: locale) }
        func gigabytes(_ value: Double) -> String { Format.number(value, decimals: value >= 10 ? 0 : 1, locale: locale) }
        switch finding.kind {
        case .heat:
            // Already two sentences: what macOS does, and what to do.
            let level: ThermalLevel = finding.severity == .problem ? .critical : .serious
            return level.advice.map { String(localized: $0) } ?? ""
        case .startupDisk, .disk:
            let disk = snapshot.disks.first { $0.name == finding.subject } ?? snapshot.startupDisk
            guard let disk else { return "" }
            return String(localized: "Only \(gigabytes(disk.freeGB)) GB free on “\(disk.name)” (\(percent(disk.freePercent))).")
        case .memory:
            let used = percent(snapshot.memoryUsed ?? 0)
            if let swap = snapshot.swapGB, swap >= 0.1 {
                return String(localized: "\(used) of memory is used and \(gigabytes(swap)) GB is written to disk (swap).")
            }
            return String(localized: "\(used) of memory is used.")
        case .battery:
            return String(localized: "The battery is at \(percent(snapshot.battery?.charge ?? 0)) and not charging.")
        case .batteryHealth:
            if let capacity = snapshot.battery?.maximumCapacity, capacity < batteryWorn {
                return String(localized: "The battery now holds \(percent(capacity)) of its original charge.")
            }
            return String(localized: "macOS recommends a battery service.")
        case .bluetooth:
            let level = snapshot.devices.first { $0.name == finding.subject }?.battery ?? 0
            return String(localized: "“\(finding.subject ?? "")” has \(percent(level)) battery left.")
        case .cpu:
            return String(localized: "The processor is \(percent(snapshot.cpu ?? 0)) busy.")
        case .gpu:
            return String(localized: "The graphics processor is \(percent(snapshot.gpu ?? 0)) busy.")
        case .network, .uptime:
            return note(finding, snapshot: snapshot, locale: locale) ?? ""
        }
    }

    /// Second sentence when one thing stands out: what to do.
    private static func advice(_ finding: DiagnosticFinding, snapshot: MacSnapshot) -> String {
        switch finding.kind {
        case .heat: ""
        case .startupDisk: String(localized: "Free up space so macOS keeps running smoothly.")
        case .disk: String(localized: "Free up space on this disk.")
        case .memory: String(localized: "Quit the apps you are not using, or restart the Mac.")
        case .battery: String(localized: "Plug in the charger soon.")
        case .batteryHealth: String(localized: "Battery settings give the details.")
        case .bluetooth: String(localized: "Charge it soon so it does not cut out.")
        case .cpu, .gpu: String(localized: "Activity Monitor shows which app uses it.")
        case .network, .uptime: ""
        }
    }

    /// A word about something that is no worry: a busy network, a long time without a restart.
    private static func note(_ finding: DiagnosticFinding, snapshot: MacSnapshot, locale: Locale) -> String? {
        switch finding.kind {
        case .network:
            let received = Format.speedText((snapshot.downloadMBps ?? 0) * 1_000_000, locale: locale)
            let sent = Format.speedText((snapshot.uploadMBps ?? 0) * 1_000_000, locale: locale)
            return String(localized: "The network is busy: \(received) received, \(sent) sent.")
        case .uptime:
            guard let hours = snapshot.uptimeHours else { return nil }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.day]
            formatter.unitsStyle = .full
            var calendar = Calendar.current
            calendar.locale = locale
            formatter.calendar = calendar
            let days = formatter.string(from: TimeInterval(hours / 24 * 86_400)) ?? ""
            return String(localized: "On for \(days) without a restart: restarting can free memory.")
        default:
            return nil
        }
    }
}

extension DiagnosticFinding.Kind {
    /// A short name for the list of other things to check.
    var topic: LocalizedStringResource {
        switch self {
        case .heat: "heat"
        case .startupDisk: "startup disk"
        case .memory: "memory"
        case .battery, .batteryHealth: "battery"
        case .disk: "disk space"
        case .bluetooth: "Bluetooth battery"
        case .cpu: "processor"
        case .gpu: "graphics"
        case .network: "network"
        case .uptime: "restart"
        }
    }
}
