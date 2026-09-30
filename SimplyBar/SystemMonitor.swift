import Foundation
import Observation
import OSLog
import WidgetKit

/// Samples every module on its own timer and keeps the recent history for the popups and the widgets.
///
/// Cost control: one coalescing timer per module (20 % tolerance). A module is sampled at its own pace while it is
/// in the menu bar or its popup is open, every minute when only a desktop widget shows it, and not at all
/// otherwise; the disk needs its fast pace only while its popup is open. An alert that is on keeps the module it
/// watches sampled every minute too. Widget data is written and reloaded every 30 minutes, and only while widgets are
/// on the desktop.
@MainActor
@Observable
final class SystemMonitor {
    static let historyLength = 50
    /// Pace of a module only a desktop widget shows, and of the disk while its popup is closed.
    static let slowInterval: TimeInterval = 60
    /// WidgetKit grants a widget a few dozen reloads a day: one every 30 minutes stays inside that budget.
    static let widgetReloadInterval: TimeInterval = 30 * 60
    /// How often the app asks WidgetKit which widgets are on the desktop.
    static let widgetCheckInterval: TimeInterval = 5 * 60

    private(set) var cpu: CPUSample?
    private(set) var cpuHistory = History(capacity: historyLength)
    private(set) var memory: MemorySample?
    private(set) var disk: DiskSample?
    /// Change of used space between two samples, in bytes (positive when space is consumed).
    private(set) var diskChanges = History(capacity: historyLength)
    private(set) var diskFlashing = false
    private(set) var network: NetworkSample?
    private(set) var uploadHistory = History(capacity: historyLength)
    private(set) var downloadHistory = History(capacity: historyLength)
    private(set) var localIP: String?
    private(set) var gpus: [GPUSample] = []
    private(set) var gpuHistory = History(capacity: historyLength)
    private(set) var bluetoothDevices: [BluetoothDevice] = []
    private(set) var bluetoothLoaded = false
    private(set) var health: HealthSample?
    let keepAwake: KeepAwakeController
    let notifier = AlertNotifier()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let cpuReader = CPUReader()
    @ObservationIgnored private let networkReader = NetworkReader()
    @ObservationIgnored private var timers: [Module: Timer] = [:]
    @ObservationIgnored private var intervals: [Module: TimeInterval] = [:]
    @ObservationIgnored private var openPopups: Set<Module> = []
    @ObservationIgnored private var widgetTimer: Timer?
    /// Kinds of the widgets on the desktop, and the modules they show.
    @ObservationIgnored private var widgetKinds: Set<String> = []
    @ObservationIgnored private var widgetModules: Set<Module> = []
    @ObservationIgnored private var lastWidgetReload = Date.distantPast
    @ObservationIgnored private var bluetoothTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    /// Date of the last Keep Awake request from the widget, handled once and written back for the widget.
    @ObservationIgnored private var lastKeepAwakeRequest: Date?
    @ObservationIgnored private var thermalObserver: (any NSObjectProtocol)?
    /// Keys of the alerts being sent right now.
    @ObservationIgnored private var sendingAlerts: Set<String> = []

    static let log = Logger(subsystem: "fr.simplibot.simplybar", category: "monitor")

    init(settings: AppSettings) {
        self.settings = settings
        keepAwake = KeepAwakeController(settings: settings)
    }

    func start() {
        settings.onChange = { [weak self] in self?.reschedule() }
        keepAwake.onChange = { [weak self] in self?.keepAwakeChanged() }
        observeKeepAwakeRequests()
        observeThermalState()
        notifier.onChange = { [weak self] in self?.reschedule() }
        notifier.activate()
        reschedule()
        logStartupNumbers()

        let timer = Timer(timeInterval: Self.widgetCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWidgets() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        widgetTimer = timer
        checkWidgets()
    }

    // MARK: - Popups

    func popupOpened(_ module: Module) {
        let running = intervals[module] != nil
        openPopups.insert(module)
        reschedule()
        // A module that just started took its first reading in reschedule(); a running one gets a fresh value now.
        if running { sample(module) }
    }

    func popupClosed(_ module: Module) {
        openPopups.remove(module)
        reschedule()
    }

    // MARK: - Scheduling

    /// Seconds between two samples of a module, or nil when nothing needs it: neither the menu bar, nor an open
    /// popup, nor a desktop widget, nor an alert that may notify.
    func interval(for module: Module) -> TimeInterval? {
        // Keep Awake measures nothing.
        if module == .keepAwake { return nil }
        let open = openPopups.contains(module)
        let pace: TimeInterval = switch module {
        case .cpu: TimeInterval(settings.cpu.interval)
        case .memory: 3
        case .network: 2
        case .disk: open ? 5 : Self.slowInterval
        case .gpu: TimeInterval(settings.gpu.interval)
        case .bluetooth: TimeInterval(settings.bluetooth.interval)
        // The heat level also arrives by notification (see `observeThermalState`).
        case .health: open ? 5 : Self.slowInterval
        case .keepAwake: 0 // Never used: returned above.
        }
        if open || settings.isShown(module) { return pace }
        // Without the permission an alert would measure for nothing: `notifier.onChange` reschedules once it comes.
        let watched = notifier.canNotify && AlertKind.allCases.contains { settings.alerts.isOn($0) && $0.module == module }
        return widgetModules.contains(module) || watched ? Self.slowInterval : nil
    }

    func reschedule() {
        for kind in AlertKind.allCases where !settings.alerts.isOn(kind) {
            settings.alertTracker.reset(kind)
        }
        for module in Module.allCases {
            let wanted = interval(for: module)
            let current = intervals[module]
            guard current != wanted else { continue }
            timers[module]?.invalidate()
            timers[module] = nil
            intervals[module] = wanted
            guard let wanted else { continue }
            var firstTick = wanted
            if current == nil {
                // A module that starts shows a value right away. CPU and network measure between two readings:
                // this one sets the start, and the first tick comes a second later instead of a full interval.
                switch module {
                case .cpu, .network:
                    prime(module)
                    firstTick = min(wanted, 1)
                case .memory, .disk, .gpu, .bluetooth, .health, .keepAwake:
                    sample(module)
                }
            }
            let timer = Timer(fire: .now.addingTimeInterval(firstTick), interval: wanted, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample(module) }
            }
            timer.tolerance = wanted * 0.2
            RunLoop.main.add(timer, forMode: .common)
            timers[module] = timer
        }
    }

    /// Takes the reference reading of a module that measures between two readings, and drops its value.
    private func prime(_ module: Module) {
        switch module {
        case .cpu: _ = cpuReader.read()
        case .network: sampleNetwork(record: false)
        default: break
        }
    }

    // MARK: - Sampling

    func sample(_ module: Module) {
        switch module {
        case .cpu:
            guard let value = cpuReader.read() else { return }
            cpu = value
            cpuHistory.append(value.total)
        case .memory:
            memory = MemoryReader.read()
        case .network:
            sampleNetwork()
        case .disk:
            sampleDisk()
        case .gpu:
            gpus = GPUReader.read()
            gpuHistory.append(gpus.map(\.utilization).max() ?? 0)
        case .bluetooth:
            guard bluetoothTask == nil else { return }
            bluetoothTask = Task { [weak self] in
                defer { self?.bluetoothTask = nil }
                let devices = await BluetoothReader.read()
                guard let self else { return }
                if devices != self.bluetoothDevices { self.bluetoothDevices = devices }
                let first = !self.bluetoothLoaded
                self.bluetoothLoaded = true
                self.checkAlerts(.bluetoothBattery) { $0.bluetooth(devices, now: $1) }
                // A first reading slower than the publication that follows a new widget: publish it now.
                if first, self.widgetKinds.contains(SharedStore.bluetoothWidgetKind) { self.publishToWidgets() }
            }
        case .health:
            // The heat alert alone needs the heat level only: the battery is read when something shows it.
            let shown = openPopups.contains(.health) || settings.isShown(.health) || widgetModules.contains(.health)
            let value = HealthReader.read(battery: shown)
            if value != health { health = value }
            checkAlerts(.heat) { $0.heat(value.thermal, now: $1) }
        case .keepAwake:
            break
        }
    }

    /// Throughput, plus the local address only while it is on screen (menu bar metric or open popup).
    private func sampleNetwork(record: Bool = true) {
        let wantsIP = openPopups.contains(.network) || (settings.network.shown && settings.network.metric == .ipAddress)
        guard let reading = networkReader.read(localIP: wantsIP) else {
            // Too soon after the previous reading (a popup that just opened): the address alone.
            if wantsIP { setLocalIP(NetworkReader.localIPAddress()) }
            return
        }
        if wantsIP { setLocalIP(reading.localIP) }
        guard record, let value = reading.sample else { return }
        network = value
        uploadHistory.append(value.upload)
        downloadHistory.append(value.download)
    }

    private func setLocalIP(_ address: String?) {
        if address != localIP { localIP = address }
    }

    private func sampleDisk() {
        guard let value = DiskReader.read() else { return }
        if let previous = disk {
            let change = value.used - previous.used
            diskChanges.append(change)
            if settings.disk.flashOnChange, DiskReader.isSignificantChange(change) { flashDisk() }
        }
        disk = value
        checkAlerts(.diskSpace) { $0.disk(value, now: $1) }
    }

    private func flashDisk() {
        diskFlashing = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.diskFlashing = false
        }
    }

    // MARK: - Widgets

    /// Only what the widgets draw: no per-core values, no startup disk name (the SSD widget shows its size, not its
    /// name), and GPU, Bluetooth devices and health only while their widgets are on the desktop.
    func widgetPayload(now: Date = .now) -> WidgetPayload {
        var payload = WidgetPayload(
            date: now,
            cpu: cpu.map { CPUSample(user: $0.user, system: $0.system, idle: $0.idle, perCore: []) },
            cpuHistory: cpuHistory.last(WidgetPayload.historyLength),
            memory: memory,
            network: network,
            uploadHistory: uploadHistory.last(WidgetPayload.historyLength),
            downloadHistory: downloadHistory.last(WidgetPayload.historyLength),
            disk: disk.map { DiskSample(name: "", total: $0.total, free: $0.free) },
            keepAwake: keepAwakeStatus
        )
        if widgetKinds.contains(SharedStore.gpuWidgetKind) {
            payload.gpu = gpus.max { $0.utilization < $1.utilization }
            payload.gpuHistory = gpuHistory.last(WidgetPayload.historyLength)
        }
        if widgetKinds.contains(SharedStore.bluetoothWidgetKind), bluetoothLoaded {
            payload.bluetooth = bluetoothDevices
        }
        if widgetKinds.contains(SharedStore.healthWidgetKind) {
            payload.health = health
        }
        return payload
    }

    /// Asks WidgetKit which widgets are on the desktop. The modules they show keep being sampled (every minute when
    /// nothing else needs them); their numbers are written and reloaded every 30 minutes, or soon after a new widget
    /// appears. Nothing is written while no widget is on the desktop.
    private func checkWidgets() {
        Task { [weak self] in
            let kinds: [String]? = await withCheckedContinuation { continuation in
                WidgetCenter.shared.getCurrentConfigurations { result in
                    continuation.resume(returning: try? result.get().map(\.kind))
                }
            }
            guard let kinds else { return }
            self?.widgetsFound(Set(kinds))
        }
    }

    private func widgetsFound(_ kinds: Set<String>) {
        let added = !kinds.isSubset(of: widgetKinds)
        if kinds != widgetKinds {
            widgetKinds = kinds
            widgetModules = Set(kinds.compactMap(Module.init(widgetKind:)))
            reschedule()
        }
        guard !kinds.isEmpty else { return }
        if added {
            // A new widget: publish once the modules it shows have a first value (a second after they start).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.publishToWidgets() }
            }
        } else if Date.now.timeIntervalSince(lastWidgetReload) >= Self.widgetReloadInterval {
            publishToWidgets()
        }
    }

    /// Writes the latest numbers for the widgets on the desktop and asks WidgetKit to redraw them all, or only the
    /// widgets of `kind` (the other ones keep their 30-minute pace).
    func publishToWidgets(onlyKind kind: String? = nil) {
        guard !widgetKinds.isEmpty else { return }
        var payload = widgetPayload()
        // Every disk, read only when a Storage widget shows them.
        if widgetKinds.contains(SharedStore.storageWidgetKind) { payload.volumes = VolumeReader.read() }
        do {
            try SharedStore.save(payload)
        } catch {
            // The description may name the container folder: only the error code is public.
            let code = (error as NSError).code
            Self.log.error("""
                Widget payload not saved: \(code, privacy: .public) \(error.localizedDescription, privacy: .private)
                """)
            return
        }
        if let kind {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        } else {
            lastWidgetReload = .now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - Heat level and alerts

    /// macOS announces a new heat level at once: the menu bar icon and the heat alert follow it without waiting for
    /// the next sample, but only while something shows or watches it.
    private func observeThermalState() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.intervals[.health] != nil else { return }
                self.sample(.health)
            }
        }
    }

    /// Runs the readings of an alert that is on through the tracker and sends what it finds due. Nothing is fed
    /// while notifications are not allowed, and the tracker only counts what macOS took: an alarm found meanwhile,
    /// or a notification that failed, still fires once they are allowed.
    private func checkAlerts(_ kind: AlertKind, _ found: (inout AlertTracker, Date) -> [DueAlert]) {
        guard settings.alerts.isOn(kind), notifier.canNotify else { return }
        // A reading that comes while the same notification is on its way does not send it twice.
        for due in found(&settings.alertTracker, .now) where sendingAlerts.isDisjoint(with: due.keys) {
            sendingAlerts.formUnion(due.keys)
            Task {
                let sent = await notifier.send(due.alert)
                sendingAlerts.subtract(due.keys)
                if sent { settings.alertTracker.sent(due, now: .now) }
            }
        }
    }

    // MARK: - Keep Awake

    private var keepAwakeStatus: KeepAwakeStatus {
        var status = keepAwake.status
        status.requestDate = lastKeepAwakeRequest
        return status
    }

    /// The Keep Awake widget follows every change at once, whoever made it.
    private func keepAwakeChanged() {
        guard widgetKinds.contains(SharedStore.keepAwakeWidgetKind) else { return }
        publishToWidgets(onlyKind: SharedStore.keepAwakeWidgetKind)
    }

    /// The widget's intent runs in the extension, which cannot keep the Mac awake: it writes a request in the App
    /// Group and posts a Darwin notification, handled here on the main thread.
    private func observeKeepAwakeRequests() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<SystemMonitor>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { monitor.keepAwakeRequested() }
                }
            },
            SharedStore.keepAwakeNotification as CFString, nil, .deliverImmediately
        )
    }

    private func keepAwakeRequested() {
        guard let request = SharedStore.loadKeepAwakeRequest(),
              request.isNew(after: lastKeepAwakeRequest, now: .now) else { return }
        lastKeepAwakeRequest = request.date
        Self.log.notice("Keep Awake requested from the widget: \(request.isActive, privacy: .public)")
        // The widget that asked is on the desktop, even if the last check has not seen it yet.
        widgetKinds.insert(SharedStore.keepAwakeWidgetKind)
        let wasActive = keepAwake.isActive
        keepAwake.isActive = request.isActive
        // A change publishes by itself; an unchanged state (a second click, a refused assertion) is confirmed too.
        if keepAwake.isActive == wasActive { publishToWidgets(onlyKind: SharedStore.keepAwakeWidgetKind) }
    }

    /// Called as the app quits: lets the Mac sleep again and tells the Keep Awake widget the app is gone. The numbers
    /// keep their date, so the other widgets still turn to "not running" on time.
    func stop() {
        keepAwake.onChange = nil
        keepAwake.isActive = false
        guard var payload = SharedStore.load(), payload.keepAwake != nil else { return }
        payload.keepAwake = nil
        try? SharedStore.save(payload)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.keepAwakeWidgetKind)
    }

    // MARK: - Diagnostics

    /// One log line to compare the sandboxed numbers with `df` and `vm_stat`. Free disk space differs by design:
    /// it includes purgeable space, and the sandbox rounds it down (see `DiskReader`).
    private func logStartupNumbers() {
        let disk = DiskReader.read()
        let blocks = DiskReader.freeBlocks()
        let memory = MemoryReader.read()
        let pages = MemoryReader.pages()
        // Proof of what the sandbox lets the app read: the heat level, the power sources, the battery registry entry.
        let health = HealthReader.read(battery: true)
        let registry = MacBatteryReader.registryProperties()
        let installed = (registry?["BatteryInstalled"] as? Bool).map(String.init(describing:)) ?? "none"
        Self.log.notice("""
            startup disk total=\(disk?.total ?? 0, privacy: .public) important=\(disk?.free ?? 0, privacy: .public) \
            blocks=\(blocks ?? 0, privacy: .public) memory total=\(memory?.total ?? 0, privacy: .public) \
            app=\(memory?.app ?? 0, privacy: .public) wired=\(memory?.wired ?? 0, privacy: .public) \
            compressed=\(memory?.compressed ?? 0, privacy: .public) \
            pages internal=\(pages?.internalPages ?? 0, privacy: .public) purgeable=\(pages?.purgeable ?? 0, privacy: .public) \
            wired=\(pages?.wired ?? 0, privacy: .public) compressor=\(pages?.compressor ?? 0, privacy: .public) \
            thermal=\(health.thermal.rawValue, privacy: .public) battery=\(health.battery != nil, privacy: .public) \
            registry keys=\(registry?.count ?? 0, privacy: .public) installed=\(installed, privacy: .public)
            """)
    }
}

extension AlertKind {
    /// The module whose readings the alert watches.
    var module: Module {
        switch self {
        case .bluetoothBattery: .bluetooth
        case .diskSpace: .disk
        case .heat: .health
        }
    }
}

extension Module {
    /// The module a desktop widget shows, from its kind (`fr.simplibot.simplybar.cpu`).
    init?(widgetKind kind: String) {
        guard kind.hasPrefix(SharedStore.widgetKindPrefix) else { return nil }
        self.init(rawValue: String(kind.dropFirst(SharedStore.widgetKindPrefix.count)))
    }
}
