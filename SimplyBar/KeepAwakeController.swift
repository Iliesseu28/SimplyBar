import Foundation
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

    /// End of the current timed session, nil while off or when it lasts until turned off.
    private(set) var end: Date?
    private var active = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var endTimer: Timer?
    /// Called after every change of state, so the widget can follow.
    @ObservationIgnored var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isActive: Bool {
        get { active }
        set { newValue ? start() : stop() }
    }

    /// The duration of the next session; changed during a session, it counts again from now.
    var duration: KeepAwakeDuration {
        get { settings.keepAwake.duration }
        set {
            settings.keepAwake.duration = newValue
            guard active else { return }
            scheduleEnd()
            onChange?()
        }
    }

    var keepsDisplayOn: Bool {
        get { settings.keepAwake.keepsDisplayOn }
        set {
            settings.keepAwake.keepsDisplayOn = newValue
            guard active else { return }
            updateDisplayAssertion()
            onChange?()
        }
    }

    var status: KeepAwakeStatus {
        KeepAwakeStatus(isActive: active, end: end, keepsDisplayOn: keepsDisplayOn)
    }

    private func start() {
        if systemAssertion == nil {
            systemAssertion = PowerAssertion.create(type: PowerAssertion.preventSystemSleep, name: Self.systemAssertionName)
        }
        guard systemAssertion != nil else {
            SystemMonitor.log.error("Keep Awake: the system sleep assertion was refused")
            return
        }
        active = true
        updateDisplayAssertion()
        scheduleEnd()
        onChange?()
    }

    private func stop() {
        guard active else { return }
        endTimer?.invalidate()
        endTimer = nil
        if let systemAssertion { PowerAssertion.release(systemAssertion) }
        systemAssertion = nil
        active = false
        end = nil
        updateDisplayAssertion()
        onChange?()
    }

    /// Holds the display assertion exactly while Keep Awake is on with the display option.
    private func updateDisplayAssertion() {
        let wanted = active && keepsDisplayOn
        if wanted, displayAssertion == nil {
            displayAssertion = PowerAssertion.create(type: PowerAssertion.preventDisplaySleep, name: Self.displayAssertionName)
        } else if !wanted, let displayAssertion {
            PowerAssertion.release(displayAssertion)
            self.displayAssertion = nil
        }
    }

    private func scheduleEnd() {
        endTimer?.invalidate()
        endTimer = nil
        end = duration.end(from: .now)
        guard let end else { return }
        // The timer fires late after a sleep (lid closed): it then ends the session right away.
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }
}
