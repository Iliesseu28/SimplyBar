import AppKit
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac awake with power assertions: idle system sleep always, idle display sleep when asked. Closing the lid
/// or choosing Sleep still puts the Mac to sleep. The assertions are released when Keep Awake is turned off, when
/// the chosen duration ends and when the app quits; macOS also drops them if the app dies.
@MainActor
@Observable
final class KeepAwakeController {
    static let systemAssertionName = "SimplyBar: Keep Awake"
    static let displayAssertionName = "SimplyBar: Keep Display On"

    private var session = KeepAwakeSession()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// Called after every change of state, so the widget can follow.
    @ObservationIgnored var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeUp() }
        }
    }

    /// End of the current timed session, nil while off or when it lasts until turned off.
    var end: Date? { session.end }

    var isActive: Bool {
        get { session.isActive }
        set { newValue ? start() : stop() }
    }

    /// The duration of the next session; changed during a session, it counts again from now.
    var duration: KeepAwakeDuration {
        get { settings.keepAwake.duration }
        set {
            settings.keepAwake.duration = newValue
            guard session.isActive else { return }
            session.change(to: newValue, now: .now)
            setEndTimer()
            onChange?()
        }
    }

    var keepsDisplayOn: Bool {
        get { settings.keepAwake.keepsDisplayOn }
        set {
            settings.keepAwake.keepsDisplayOn = newValue
            guard session.isActive else { return }
            updateDisplayAssertion()
            onChange?()
        }
    }

    var status: KeepAwakeStatus {
        KeepAwakeStatus(isActive: session.isActive, end: session.end, keepsDisplayOn: keepsDisplayOn)
    }

    private func start() {
        // Already on: the countdown goes on and nothing is published twice.
        guard !session.isActive else { return }
        if systemAssertion == nil {
            systemAssertion = PowerAssertion.create(type: PowerAssertion.preventSystemSleep, name: Self.systemAssertionName)
        }
        guard systemAssertion != nil else {
            SystemMonitor.log.error("Keep Awake: the system sleep assertion was refused")
            return
        }
        _ = session.start(duration, now: .now)
        updateDisplayAssertion()
        setEndTimer()
        onChange?()
    }

    private func stop() {
        guard session.stop() else { return }
        endTimer?.invalidate()
        endTimer = nil
        if let systemAssertion { PowerAssertion.release(systemAssertion) }
        systemAssertion = nil
        updateDisplayAssertion()
        onChange?()
    }

    /// Holds the display assertion exactly while Keep Awake is on with the display option.
    private func updateDisplayAssertion() {
        let wanted = session.isActive && keepsDisplayOn
        if wanted, displayAssertion == nil {
            displayAssertion = PowerAssertion.create(type: PowerAssertion.preventDisplaySleep, name: Self.displayAssertionName)
        } else if !wanted, let displayAssertion {
            PowerAssertion.release(displayAssertion)
            self.displayAssertion = nil
        }
    }

    /// Sets the timer for the end of the session, none when it lasts until turned off.
    private func setEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
        guard let end = session.end else { return }
        // The timer's clock stops while the Mac sleeps, so it would fire late by the time slept: `wokeUp()` ends the
        // session or sets the timer again.
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func wokeUp() {
        switch session.afterWake(now: .now) {
        case .nothing: break
        case .stop: stop()
        case .setTimer: setEndTimer()
        }
    }
}
