import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable, Identifiable {
    case module(Module)
    case alerts
    case general
    case about

    static let all: [SettingsTab] = Module.allCases.map { .module($0) } + [.alerts, .general, .about]

    var id: String {
        switch self {
        case .module(let module): module.rawValue
        case .alerts: "alerts"
        case .general: "general"
        case .about: "about"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .module(let module): module.title
        case .alerts: "Alerts"
        case .general: "General"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .module(let module): module.symbol
        case .alerts: "bell.badge"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// Opens at login through `SMAppService.mainApp` (macOS 13+, allowed for Mac App Store apps). Off by default.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let code = (error as NSError).code
            SystemMonitor.log.error("""
                Login item change failed: \(code, privacy: .public) \(error.localizedDescription, privacy: .private)
                """)
        }
    }
}

/// The settings window, kept in AppKit so the popups and a relaunch can open it from anywhere.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(tab: SettingsTab = .module(.cpu)) {
        selection.tab = tab
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                settings: AppServices.settings, keepAwake: AppServices.monitor.keepAwake,
                notifier: AppServices.monitor.notifier, selection: selection
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "SimplyBar Settings")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 700, height: 440))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("SimplyBarSettings")
            if !window.setFrameUsingName("SimplyBarSettings") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class SettingsSelection {
    var tab: SettingsTab? = .module(.cpu)
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var keepAwake: KeepAwakeController
    let notifier: AlertNotifier
    @Bindable var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.all, selection: $selection.tab) { tab in
                Label { Text(tab.title) } icon: { Image(systemName: tab.symbol) }
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(170)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Quit") { NSApp.terminate(nil) }
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            let tab = selection.tab ?? .module(.cpu)
            if case .module(let module) = tab, !settings.isShown(module) {
                // A module left out of the menu bar shows only the switch that brings it back.
                Toggle("Show in menu bar", isOn: shown(module))
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .about {
                AboutView()
            } else {
                Form {
                    detail
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private func shown(_ module: Module) -> Binding<Bool> {
        Binding(get: { settings.isShown(module) }, set: { settings.setShown(module, $0) })
    }

    @ViewBuilder private var detail: some View {
        switch selection.tab ?? .module(.cpu) {
        case .module(.cpu): cpu
        case .module(.memory): memory
        case .module(.gpu): gpu
        case .module(.network): network
        case .module(.disk): disk
        case .module(.bluetooth): bluetooth
        case .module(.health): health
        case .module(.diagnostic): DiagnosticSettingsView(settings: settings)
        case .module(.keepAwake): keepAwakeSettings
        case .alerts: AlertsSettings(settings: settings, notifier: notifier)
        case .general: GeneralSettings(settings: settings)
        case .about: EmptyView() // Laid out on its own, outside the form.
        }
    }

    private var cpu: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.cpu.shown)
            IntervalPicker(value: $settings.cpu.interval, options: Sampling.intervals)
            Toggle("Show icon", isOn: $settings.cpu.showIcon)
            Toggle("Show label", isOn: $settings.cpu.showLabel)
            Picker("Metric:", selection: $settings.cpu.metric) {
                ForEach(CPUMetric.allCases) { Text($0.title).tag($0) }
            }
            StylePicker(value: $settings.cpu.style, options: [.bar, .percent])
        }
    }

    private var memory: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.memory.shown)
            Toggle("Show icon", isOn: $settings.memory.showIcon)
            Toggle("Show label", isOn: $settings.memory.showLabel)
            Picker("Metric:", selection: $settings.memory.metric) {
                ForEach(MemoryMetric.allCases) { Text($0.title).tag($0) }
            }
            StylePicker(value: $settings.memory.style, options: ValueStyle.allCases)
        }
    }

    private var gpu: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.gpu.shown)
            IntervalPicker(value: $settings.gpu.interval, options: Sampling.intervals)
            Toggle("Show icon", isOn: $settings.gpu.showIcon)
            Toggle("Show label", isOn: $settings.gpu.showLabel)
            StylePicker(value: $settings.gpu.style, options: [.bar, .percent])
        }
    }

    private var network: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.network.shown)
            Toggle("Show icon", isOn: $settings.network.showIcon)
            Toggle("Show label", isOn: $settings.network.showLabel)
            Picker("Metric:", selection: $settings.network.metric) {
                ForEach(NetworkMetric.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var disk: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.disk.shown)
            Toggle("Show icon", isOn: $settings.disk.showIcon)
            Toggle("Show label", isOn: $settings.disk.showLabel)
            Toggle("Flash red on significant changes", isOn: $settings.disk.flashOnChange)
            Picker("Metric:", selection: $settings.disk.metric) {
                ForEach(DiskMetric.allCases) { Text($0.title).tag($0) }
            }
            StylePicker(value: $settings.disk.style, options: ValueStyle.allCases)
        }
    }

    private var bluetooth: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.bluetooth.shown)
            IntervalPicker(value: $settings.bluetooth.interval, options: Sampling.bluetoothIntervals)
            Toggle("Show icon", isOn: $settings.bluetooth.showIcon)
            Toggle("Show label", isOn: $settings.bluetooth.showLabel)
        }
    }

    private var health: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.health.shown)
            Text("The icon turns yellow, orange or red as the Mac heats up.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var keepAwakeSettings: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.keepAwake.shown)
            // Also here: with the item hidden, a session started from the widget can still be stopped.
            Toggle("Keep this Mac awake", isOn: $keepAwake.isActive)
            if keepAwake.isActive, let end = keepAwake.end {
                KeepAwakeTimeLeft(end: end)
            }
            KeepAwakeDurationPicker(duration: $keepAwake.duration)
            Toggle("Keep the display on too", isOn: $keepAwake.keepsDisplayOn)
        }
    }
}

/// The Diagnostic tab: the menu bar item, and what Apple Intelligence can do on this Mac.
struct DiagnosticSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle("Show in menu bar", isOn: $settings.diagnostic.shown)
            Text("""
                Rules check the processor, memory, disks, heat and batteries on every Mac. Where Apple Intelligence \
                is available, its on-device model explains the result and answers your questions. Nothing leaves \
                your Mac.
                """)
                .font(.callout).foregroundStyle(.secondary)
            Text(DiagnosticAIStatus.current(language: .app).message ?? String(localized: "Apple Intelligence is available."))
                .font(.callout)
        }
    }
}

/// Also in the Keep Awake popup: the duration of the next session.
struct KeepAwakeDurationPicker: View {
    @Binding var duration: KeepAwakeDuration

    var body: some View {
        Picker("Duration:", selection: $duration) {
            ForEach(KeepAwakeDuration.allCases) { Text($0.title).tag($0) }
        }
    }
}

private struct IntervalPicker: View {
    @Binding var value: Int
    let options: [Int]

    var body: some View {
        Picker("Update interval (seconds):", selection: $value) {
            ForEach(options, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
    }
}

private struct StylePicker: View {
    @Binding var value: ValueStyle
    let options: [ValueStyle]

    var body: some View {
        Picker("Style:", selection: $value) {
            ForEach(options) { $0.label.tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

/// One switch per alert, all off at first. Turning one on asks for permission to notify, once.
private struct AlertsSettings: View {
    @Bindable var settings: AppSettings
    let notifier: AlertNotifier

    var body: some View {
        Section {
            Toggle(isOn: binding(.bluetoothBattery)) {
                Text("Bluetooth battery low")
                Text("When a device drops to \(Format.percent(Double(AlertRules.bluetoothLow) / 100)) or less.")
            }
            Toggle(isOn: binding(.diskSpace)) {
                Text("Startup disk almost full")
                Text("When less than \(Format.percent(AlertRules.diskLow)) of the startup disk is free.")
            }
            Toggle(isOn: binding(.heat)) {
                Text("Mac running hot")
                Text("When macOS reports the Mac as hot or critical.")
            }
        } footer: {
            Text("An alert comes back only once things are back to normal, and at most once an hour.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .task { await notifier.refreshStatus() }
        // Permission is granted or withdrawn in System Settings: read it again when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refreshStatus() }
        }
        if AlertKind.allCases.contains(where: settings.alerts.isOn) {
            switch notifier.status {
            case .denied?:
                Section {
                    Text("Notifications are off for SimplyBar.")
                    Button("Open Notification Settings") { notifier.openSystemSettings() }
                }
            // The macOS prompt was closed without an answer: ask again.
            case .notDetermined?:
                Section {
                    Text("SimplyBar is not allowed to send notifications yet.")
                    Button("Allow Notifications") { Task { await notifier.requestAuthorization() } }
                }
            default:
                EmptyView()
            }
        }
    }

    private func binding(_ kind: AlertKind) -> Binding<Bool> {
        Binding(get: { settings.alerts.isOn(kind) }, set: { on in
            settings.alerts.set(kind, on)
            if on { Task { await notifier.requestAuthorization() } }
        })
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    // Reading the status back below changes the toggle again: only act on a real change,
                    // otherwise a registration waiting for approval would undo itself.
                    guard enabled != LoginItem.isEnabled else { return }
                    LoginItem.set(enabled)
                    refresh()
                }
            if needsApproval {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Requires approval in System Settings > General > Login Items.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Toggle("Open Settings at launch", isOn: $settings.openSettingsAtLaunch)
        }
        .onAppear(perform: refresh)
        // The approval happens in System Settings: read the status again when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        launchAtLogin = LoginItem.isEnabled
        needsApproval = LoginItem.needsApproval
    }
}

/// About and support: the app's name and version, then blocks of text and links (store review, legal pages,
/// contact).
private struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "SimplyBar").font(.headline)
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("Made by Simplibot.").foregroundStyle(.secondary)
                }
            }
            block("Enjoying SimplyBar?") {
                if let review = AppLinks.appStoreReview {
                    Link("Rate it on the Mac App Store", destination: review)
                } else {
                    Text("Rate it on the Mac App Store")
                        .foregroundStyle(.tertiary)
                        .help("Available once SimplyBar is on the Mac App Store.")
                }
            }
            block("Legal") {
                Link("Privacy Policy", destination: AppLinks.privacy)
                Text("SimplyBar collects no data. Every measurement stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
            block("Have a question?") {
                HStack(spacing: 6) {
                    Text("Email us at:")
                    Link(AppLinks.contactEmail, destination: AppLinks.contact)
                    CopyButton(text: AppLinks.contactEmail)
                }
                Link("Support", destination: AppLinks.support)
                Link("Website", destination: AppLinks.site)
                Link("Source Code on GitHub", destination: AppLinks.sourceCode)
            }
        }
        // A fixed width: measured at a narrow width, wrapping text would ask for a very tall window and push
        // the sidebar out of view.
        .frame(width: 360, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func block(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            content()
        }
    }
}
