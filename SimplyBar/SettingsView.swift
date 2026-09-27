import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: Hashable, Identifiable {
    case module(Module)
    case general
    case about

    static let all: [SettingsTab] = Module.allCases.map { .module($0) } + [.general, .about]

    var id: String {
        switch self {
        case .module(let module): module.rawValue
        case .general: "general"
        case .about: "about"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .module(let module): module.title
        case .general: "General"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .module(let module): module.symbol
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
                settings: AppServices.settings, selection: selection
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
