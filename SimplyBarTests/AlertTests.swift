import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

private func device(_ name: String, _ percent: Int, address: String? = nil) -> BluetoothDevice {
    BluetoothDevice(name: name, address: address, levels: [.init(part: .main, percent: percent)])
}

private let gb = 1_000_000_000.0

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
        #expect(tracker.update("x", .normal, now: start) == false)
        #expect(tracker.update("x", .alarm, now: minutes(1)) == true)
        // Still in alarm, even hours later: silent.
        #expect(tracker.update("x", .alarm, now: minutes(2)) == false)
        #expect(tracker.update("x", .alarm, now: minutes(300)) == false)
        // Back to normal, then in alarm again past the hour: fires again.
        #expect(tracker.update("x", .normal, now: minutes(301)) == false)
        #expect(tracker.update("x", .alarm, now: minutes(302)) == true)
    }

    @Test func hoveringAroundTheThresholdDoesNotReArm() {
        var tracker = AlertTracker()
        #expect(tracker.update("x", .alarm, now: start) == true)
        #expect(tracker.update("x", .near, now: minutes(90)) == false)
        #expect(tracker.update("x", .alarm, now: minutes(120)) == false)
    }

    @Test func neverTwiceWithinAnHourAndHeldBackAlarmsFireLater() {
        var tracker = AlertTracker()
        #expect(tracker.update("x", .alarm, now: start) == true)
        #expect(tracker.update("x", .normal, now: minutes(5)) == false)
        // Back in alarm 10 minutes after the first notification: held back.
        #expect(tracker.update("x", .alarm, now: minutes(10)) == false)
        #expect(tracker.update("x", .alarm, now: minutes(59)) == false)
        // Still in alarm once the hour has passed: it goes out now, once.
        #expect(tracker.update("x", .alarm, now: minutes(60)) == true)
        #expect(tracker.update("x", .alarm, now: minutes(61)) == false)
    }

    @Test func objectsAreTrackedApart() {
        var tracker = AlertTracker()
        let alerts = tracker.bluetooth([device("Mouse", 15, address: "AA:AA:AA:AA:AA:AA"),
                                        device("Keyboard", 60, address: "BB:BB:BB:BB:BB:BB")], now: start)
        #expect(alerts == [.bluetoothBattery(device: "Mouse", percent: 15)])
        // The keyboard drops a minute later: it has its own hour.
        let later = tracker.bluetooth([device("Mouse", 14, address: "AA:AA:AA:AA:AA:AA"),
                                       device("Keyboard", 19, address: "BB:BB:BB:BB:BB:BB")], now: minutes(1))
        #expect(later == [.bluetoothBattery(device: "Keyboard", percent: 19)])
    }

    @Test func bluetoothUsesTheLowestPartAndSkipsDevicesWithoutBattery() {
        var tracker = AlertTracker()
        let earbuds = BluetoothDevice(name: "Earbuds", levels: [.init(part: .left, percent: 80), .init(part: .right, percent: 18)])
        let speaker = BluetoothDevice(name: "Speaker", levels: [])
        #expect(tracker.bluetooth([earbuds, speaker], now: start) == [.bluetoothBattery(device: "Earbuds", percent: 18)])
        // Disconnected, then back still low: no second alert, it never went back to normal.
        #expect(tracker.bluetooth([], now: minutes(30)).isEmpty)
        #expect(tracker.bluetooth([earbuds], now: minutes(90)).isEmpty)
    }

    @Test func diskAndHeatFollowTheSameRules() {
        var tracker = AlertTracker()
        let full = DiskSample(name: "", total: 500 * gb, free: 20 * gb)
        #expect(tracker.disk(full, now: start) == [.diskSpace(free: 20 * gb, total: 500 * gb)])
        #expect(tracker.disk(full, now: minutes(120)).isEmpty)
        #expect(tracker.heat(.fair, now: start).isEmpty)
        #expect(tracker.heat(.serious, now: start) == [.heat(.serious)])
        // Hot to critical is the same episode: no second notification.
        #expect(tracker.heat(.critical, now: minutes(70)).isEmpty)
        #expect(tracker.heat(.nominal, now: minutes(80)).isEmpty)
        #expect(tracker.heat(.critical, now: minutes(81)) == [.heat(.critical)])
    }

    @Test func resetRearmsOneKindButKeepsTheHour() {
        var tracker = AlertTracker()
        #expect(tracker.heat(.serious, now: start).count == 1)
        #expect(tracker.bluetooth([device("Mouse", 10)], now: start).count == 1)
        tracker.reset(.heat)
        // Turned off and on again: the hour still holds, then it fires without a return to normal.
        #expect(tracker.heat(.serious, now: minutes(30)).isEmpty)
        #expect(tracker.heat(.serious, now: minutes(61)).count == 1)
        // The other kinds are untouched.
        #expect(tracker.bluetooth([device("Mouse", 10)], now: minutes(61)).isEmpty)
    }

    @Test func trackerSurvivesARelaunch() throws {
        var tracker = AlertTracker()
        #expect(tracker.heat(.critical, now: start).count == 1)
        var restored = try JSONDecoder().decode(AlertTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored == tracker)
        #expect(restored.heat(.critical, now: minutes(5)).isEmpty)
    }
}
