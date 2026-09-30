import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

private func device(_ name: String, _ percent: Int, address: String? = nil) -> BluetoothDevice {
    BluetoothDevice(name: name, address: address, levels: [.init(part: .main, percent: percent)])
}

private let gb = 1_000_000_000.0

extension AlertTracker {
    /// A reading whose due notifications all go out, as when macOS takes them: returns what was sent.
    mutating func deliver(now: Date, _ reading: (inout AlertTracker, Date) -> [DueAlert]) -> [Alert] {
        let due = reading(&self, now)
        for item in due { sent(item, now: now) }
        return due.map(\.alert)
    }

    /// `update`, with the notification sent whenever it is due.
    mutating func fire(_ key: String, _ level: AlertLevel, now: Date) -> Bool {
        guard update(key, level, now: now) else { return false }
        sent(DueAlert(alert: .heat(.serious), keys: [key]), now: now)
        return true
    }
}

struct AlertRuleTests {
    @Test func bluetoothThresholdsLeaveAMargin() {
        #expect(AlertRules.bluetooth(0) == .alarm)
        #expect(AlertRules.bluetooth(20) == .alarm)
        #expect(AlertRules.bluetooth(21) == .near)
        #expect(AlertRules.bluetooth(24) == .near)
        #expect(AlertRules.bluetooth(25) == .normal)
        #expect(AlertRules.bluetooth(100) == .normal)
    }

    @Test func diskThresholdsLeaveAMargin() {
        #expect(AlertRules.disk(free: 9.9 * gb, total: 100 * gb) == .alarm)
        #expect(AlertRules.disk(free: 10 * gb, total: 100 * gb) == .near)
        #expect(AlertRules.disk(free: 11.9 * gb, total: 100 * gb) == .near)
        #expect(AlertRules.disk(free: 12 * gb, total: 100 * gb) == .normal)
        #expect(AlertRules.disk(free: 0, total: 0) == .normal)
    }

    @Test func onlyHotAndCriticalAlarm() {
        #expect(AlertRules.heat(.nominal) == .normal)
        #expect(AlertRules.heat(.fair) == .normal)
        #expect(AlertRules.heat(.serious) == .alarm)
        #expect(AlertRules.heat(.critical) == .alarm)
        // Critical has its own level: back to hot is not over.
        #expect(AlertRules.criticalHeat(.fair) == .normal)
        #expect(AlertRules.criticalHeat(.serious) == .near)
        #expect(AlertRules.criticalHeat(.critical) == .alarm)
    }

    @Test func everyAlertStartsOffAndSavedValuesAreKept() throws {
        let fresh = AlertSettings()
        #expect(AlertKind.allCases.allSatisfy { !fresh.isOn($0) })
        let saved = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"heat":true,"unknown":1}"#.utf8))
        #expect(saved.isOn(.heat) && !saved.isOn(.bluetoothBattery) && !saved.isOn(.diskSpace))
        var settings = AlertSettings()
        settings.set(.diskSpace, true)
        let decoded = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

struct AlertTrackerTests {
    @Test func firesOnceUntilBackToNormal() {
        var tracker = AlertTracker()
        #expect(tracker.fire("x", .normal, now: start) == false)
        #expect(tracker.fire("x", .alarm, now: minutes(1)) == true)
        // Still in alarm, even hours later: silent.
        #expect(tracker.fire("x", .alarm, now: minutes(2)) == false)
        #expect(tracker.fire("x", .alarm, now: minutes(300)) == false)
        // Back to normal, then in alarm again past the hour: fires again.
        #expect(tracker.fire("x", .normal, now: minutes(301)) == false)
        #expect(tracker.fire("x", .alarm, now: minutes(302)) == true)
    }

    @Test func hoveringAroundTheThresholdDoesNotReArm() {
        var tracker = AlertTracker()
        #expect(tracker.fire("x", .alarm, now: start) == true)
        #expect(tracker.fire("x", .near, now: minutes(90)) == false)
        #expect(tracker.fire("x", .alarm, now: minutes(120)) == false)
    }

    @Test func neverTwiceWithinAnHourAndHeldBackAlarmsFireLater() {
        var tracker = AlertTracker()
        #expect(tracker.fire("x", .alarm, now: start) == true)
        #expect(tracker.fire("x", .normal, now: minutes(5)) == false)
        // Back in alarm 10 minutes after the first notification: held back.
        #expect(tracker.fire("x", .alarm, now: minutes(10)) == false)
        #expect(tracker.fire("x", .alarm, now: minutes(59)) == false)
        // Still in alarm once the hour has passed: it goes out now, once.
        #expect(tracker.fire("x", .alarm, now: minutes(60)) == true)
        #expect(tracker.fire("x", .alarm, now: minutes(61)) == false)
    }

    @Test func aNotificationThatFailedDoesNotCount() {
        var tracker = AlertTracker()
        // Due, but never sent (permission withdrawn in System Settings, or macOS refused it).
        #expect(tracker.heat(.serious, now: start).map(\.alert) == [.heat(.serious)])
        #expect(tracker.waiting.isEmpty && tracker.lastFired.isEmpty)
        // Still due on the next reading, and counted once it goes out.
        #expect(tracker.deliver(now: minutes(1)) { $0.heat(.serious, now: $1) } == [.heat(.serious)])
        #expect(tracker.deliver(now: minutes(2)) { $0.heat(.serious, now: $1) }.isEmpty)
    }

    @Test func objectsAreTrackedApart() {
        var tracker = AlertTracker()
        let alerts = tracker.deliver(now: start) {
            $0.bluetooth([device("Mouse", 15, address: "AA:AA:AA:AA:AA:AA"),
                          device("Keyboard", 60, address: "BB:BB:BB:BB:BB:BB")], now: $1)
        }
        #expect(alerts == [.bluetoothBattery(device: "Mouse", percent: 15)])
        // The keyboard drops a minute later: it has its own hour.
        let later = tracker.deliver(now: minutes(1)) {
            $0.bluetooth([device("Mouse", 14, address: "AA:AA:AA:AA:AA:AA"),
                          device("Keyboard", 19, address: "BB:BB:BB:BB:BB:BB")], now: $1)
        }
        #expect(later == [.bluetoothBattery(device: "Keyboard", percent: 19)])
    }

    @Test func bluetoothUsesTheLowestPartAndSkipsDevicesWithoutBattery() {
        var tracker = AlertTracker()
        let earbuds = BluetoothDevice(name: "Earbuds", levels: [.init(part: .left, percent: 80), .init(part: .right, percent: 18)])
        let speaker = BluetoothDevice(name: "Speaker", levels: [])
        #expect(tracker.deliver(now: start) { $0.bluetooth([earbuds, speaker], now: $1) }
                == [.bluetoothBattery(device: "Earbuds", percent: 18)])
        // Disconnected, then back still low: no second alert, it never went back to normal.
        #expect(tracker.deliver(now: minutes(30)) { $0.bluetooth([], now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(90)) { $0.bluetooth([earbuds], now: $1) }.isEmpty)
    }

    @Test func diskAndHeatFollowTheSameRules() {
        var tracker = AlertTracker()
        let full = DiskSample(name: "", total: 500 * gb, free: 20 * gb)
        #expect(tracker.deliver(now: start) { $0.disk(full, now: $1) } == [.diskSpace(free: 20 * gb, total: 500 * gb)])
        #expect(tracker.deliver(now: minutes(120)) { $0.disk(full, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: start) { $0.heat(.fair, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: start) { $0.heat(.serious, now: $1) } == [.heat(.serious)])
        #expect(tracker.deliver(now: minutes(90)) { $0.heat(.serious, now: $1) }.isEmpty)
    }

    @Test func criticalAfterHotNotifiesAgain() {
        var tracker = AlertTracker()
        #expect(tracker.deliver(now: start) { $0.heat(.serious, now: $1) } == [.heat(.serious)])
        // Critical five minutes later, while hot still waits: its own notification.
        #expect(tracker.deliver(now: minutes(5)) { $0.heat(.critical, now: $1) } == [.heat(.critical)])
        #expect(tracker.deliver(now: minutes(6)) { $0.heat(.critical, now: $1) }.isEmpty)
        // Back down to hot, then up to critical again: the same episode, silent.
        #expect(tracker.deliver(now: minutes(7)) { $0.heat(.serious, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(70)) { $0.heat(.critical, now: $1) }.isEmpty)
        // Back to normal re-arms both, past the hour.
        #expect(tracker.deliver(now: minutes(80)) { $0.heat(.nominal, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(81)) { $0.heat(.serious, now: $1) } == [.heat(.serious)])
    }

    @Test func straightToCriticalSendsOneNotificationAndCoversHot() {
        var tracker = AlertTracker()
        #expect(tracker.deliver(now: start) { $0.heat(.critical, now: $1) } == [.heat(.critical)])
        // Cooling down to hot is no news.
        #expect(tracker.deliver(now: minutes(10)) { $0.heat(.serious, now: $1) }.isEmpty)
        // Normal, then hot again within the hour: held back like any object.
        #expect(tracker.deliver(now: minutes(20)) { $0.heat(.fair, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(30)) { $0.heat(.serious, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(61)) { $0.heat(.serious, now: $1) } == [.heat(.serious)])
    }

    @Test func oldEntriesArePurged() {
        var tracker = AlertTracker()
        #expect(tracker.fire("gone", .alarm, now: start) == true)
        #expect(tracker.fire("gone", .normal, now: minutes(5)) == false)
        #expect(tracker.fire("still", .alarm, now: start) == true)
        // Past the hour, the next notification drops the entry that no longer waits, and keeps the one that does.
        #expect(tracker.fire("new", .alarm, now: minutes(61)) == true)
        #expect(Set(tracker.lastFired.keys) == ["still", "new"])
        #expect(tracker.waiting == ["still", "new"])
    }

    @Test func resetRearmsOneKindButKeepsTheHour() {
        var tracker = AlertTracker()
        #expect(tracker.deliver(now: start) { $0.heat(.serious, now: $1) }.count == 1)
        #expect(tracker.deliver(now: start) { $0.bluetooth([device("Mouse", 10)], now: $1) }.count == 1)
        tracker.reset(.heat)
        // Turned off and on again: the hour still holds, then it fires without a return to normal.
        #expect(tracker.deliver(now: minutes(30)) { $0.heat(.serious, now: $1) }.isEmpty)
        #expect(tracker.deliver(now: minutes(61)) { $0.heat(.serious, now: $1) }.count == 1)
        // The other kinds are untouched.
        #expect(tracker.deliver(now: minutes(61)) { $0.bluetooth([device("Mouse", 10)], now: $1) }.isEmpty)
    }

    @Test func trackerSurvivesARelaunch() throws {
        var tracker = AlertTracker()
        #expect(tracker.deliver(now: start) { $0.heat(.critical, now: $1) }.count == 1)
        var restored = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored == tracker)
        #expect(restored.deliver(now: minutes(5)) { $0.heat(.critical, now: $1) }.isEmpty)
    }
}
