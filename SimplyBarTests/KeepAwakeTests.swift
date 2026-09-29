import Foundation
import Testing

private let start = Date(timeIntervalSince1970: 1_790_000_000)

struct KeepAwakeTests {
    @Test func durationsEndAfterTheirLength() {
        #expect(KeepAwakeDuration.indefinitely.end(from: start) == nil)
        #expect(KeepAwakeDuration.thirtyMinutes.end(from: start) == start.addingTimeInterval(30 * 60))
        #expect(KeepAwakeDuration.oneHour.end(from: start) == start.addingTimeInterval(60 * 60))
        #expect(KeepAwakeDuration.twoHours.end(from: start) == start.addingTimeInterval(2 * 60 * 60))
        #expect(KeepAwakeDuration.fourHours.end(from: start) == start.addingTimeInterval(4 * 60 * 60))
        #expect(KeepAwakeDuration.allCases.count == 5)
    }

    @Test func timedSessionIsOffOnceItsEndIsPassed() {
        let status = KeepAwakeStatus(isActive: true, end: start.addingTimeInterval(1_800), keepsDisplayOn: false)
        #expect(status.isActive(at: start))
        #expect(status.remaining(at: start.addingTimeInterval(600)) == 1_200)
        #expect(!status.isActive(at: start.addingTimeInterval(1_800)))
        #expect(status.remaining(at: start.addingTimeInterval(1_801)) == nil)
    }

    @Test func untimedSessionLastsAndOffStaysOff() {
        let untimed = KeepAwakeStatus(isActive: true, end: nil, keepsDisplayOn: true)
        #expect(untimed.isActive(at: start.addingTimeInterval(86_400)))
        #expect(untimed.remaining(at: start) == nil)
        let off = KeepAwakeStatus(isActive: false, end: nil, keepsDisplayOn: false)
        #expect(!off.isActive(at: start))
    }

    @Test func widgetShowsTheAppsWord() throws {
        let status = KeepAwakeStatus(isActive: true, end: start.addingTimeInterval(1_800), keepsDisplayOn: false)
        let payload = WidgetPayload(date: start, keepAwake: status)
        let state = try #require(KeepAwakeWidgetState.resolve(payload: payload, request: nil, now: start.addingTimeInterval(60)))
        #expect(state.isActive && !state.isPending)
        #expect(state.end == status.end && state.date == start)
        // Past the end the widget turns off by itself, before the app says so.
        let later = try #require(KeepAwakeWidgetState.resolve(payload: payload, request: nil, now: start.addingTimeInterval(1_800)))
        #expect(!later.isActive && later.end == nil)
    }

    @Test func unansweredRequestShowsForTenSeconds() throws {
        let payload = WidgetPayload(date: start, keepAwake: KeepAwakeStatus(isActive: false, end: nil, keepsDisplayOn: false))
        let request = KeepAwakeRequest(isActive: true, date: start.addingTimeInterval(5))
        let asked = try #require(KeepAwakeWidgetState.resolve(payload: payload, request: request, now: start.addingTimeInterval(6)))
        #expect(asked.isActive && asked.isPending && asked.end == nil)
        // No answer: back to what the app last wrote.
        let expired = try #require(KeepAwakeWidgetState.resolve(payload: payload, request: request, now: start.addingTimeInterval(16)))
        #expect(!expired.isActive && !expired.isPending)
    }

    @Test func answeredRequestGivesWayToTheApp() throws {
        let request = KeepAwakeRequest(isActive: true, date: start)
        // The app answered after the request: it wins, even if it refused.
        let payload = WidgetPayload(date: start.addingTimeInterval(1), keepAwake: KeepAwakeStatus(isActive: false, end: nil, keepsDisplayOn: false))
        let state = try #require(KeepAwakeWidgetState.resolve(payload: payload, request: request, now: start.addingTimeInterval(2)))
        #expect(!state.isActive && !state.isPending)
    }

    @Test func widgetSaysNotRunningWithoutAFreshAnswer() {
        let status = KeepAwakeStatus(isActive: true, end: nil, keepsDisplayOn: false)
        #expect(KeepAwakeWidgetState.resolve(payload: nil, request: nil, now: start) == nil)
        // The app quit: it removed Keep Awake from the file.
        #expect(KeepAwakeWidgetState.resolve(payload: WidgetPayload(date: start), request: nil, now: start) == nil)
        let old = WidgetPayload(date: start, keepAwake: status)
        #expect(KeepAwakeWidgetState.resolve(payload: old, request: nil, now: start.addingTimeInterval(SharedStore.freshness + 1)) == nil)
    }

    @Test func requestSurvivesTheSharedFile() throws {
        let request = KeepAwakeRequest(isActive: true, date: start)
        #expect(try SharedStore.decodeRequest(SharedStore.encode(request)) == request)
        #expect(throws: (any Error).self) { try SharedStore.decodeRequest(Data(#"{"date":1790000000}"#.utf8)) }
    }

    @Test func settingsKeepTheirDefaultsForMissingOrUnknownValues() throws {
        let empty = try JSONDecoder().decode(KeepAwakeSettings.self, from: Data("{}".utf8))
        #expect(empty == KeepAwakeSettings())
        #expect(empty.shown && empty.duration == .indefinitely && !empty.keepsDisplayOn)
        let partial = try JSONDecoder().decode(KeepAwakeSettings.self, from: Data(#"{"shown":false,"duration":999}"#.utf8))
        #expect(!partial.shown && partial.duration == .indefinitely)
        var saved = KeepAwakeSettings()
        saved.duration = .twoHours
        saved.keepsDisplayOn = true
        #expect(try JSONDecoder().decode(KeepAwakeSettings.self, from: JSONEncoder().encode(saved)) == saved)
    }

    /// The real IOKit call, outside the sandbox: the assertion is listed while held and gone once released.
    @Test func powerAssertionIsHeldThenReleased() throws {
        let name = "SimplyBar test \(UUID().uuidString)"
        let id = try #require(PowerAssertion.create(type: PowerAssertion.preventSystemSleep, name: name))
        #expect(PowerAssertion.namesHeldByThisProcess().contains(name))
        PowerAssertion.release(id)
        #expect(!PowerAssertion.namesHeldByThisProcess().contains(name))
    }
}

struct WidgetPayloadDecodingTests {
    @Test func missingKeysDecodeAsEmpty() throws {
        let payload = try SharedStore.decode(Data(#"{"date":1790000000}"#.utf8))
        #expect(payload == WidgetPayload(date: start))
        #expect(payload.cpuHistory.isEmpty && payload.gpuHistory.isEmpty)
        #expect(payload.gpu == nil && payload.bluetooth == nil && payload.keepAwake == nil)
    }

    @Test func aValueInAnotherShapeOnlyLosesThatValue() throws {
        let data = Data("""
            {"date":1790000000,"cpuHistory":"broken","gpu":[1,2],"bluetooth":{"name":"x"},
             "keepAwake":{"isActive":true,"keepsDisplayOn":false},"gpuHistory":[0.5]}
            """.utf8)
        let payload = try SharedStore.decode(data)
        #expect(payload.cpuHistory.isEmpty && payload.gpu == nil && payload.bluetooth == nil)
        #expect(payload.gpuHistory == [0.5])
        #expect(payload.keepAwake == KeepAwakeStatus(isActive: true, end: nil, keepsDisplayOn: false))
    }

    @Test func newValuesSurviveTheSharedFile() throws {
        let payload = WidgetPayload(
            date: start,
            gpu: GPUSample(model: "Apple M3", utilization: 0.4), gpuHistory: [0.1, 0.4],
            bluetooth: [BluetoothDevice(name: "Keyboard", address: "00:11:22:33:44:55", levels: [.init(part: .main, percent: 78)])],
            keepAwake: KeepAwakeStatus(isActive: true, end: start.addingTimeInterval(1_800), keepsDisplayOn: true)
        )
        #expect(try SharedStore.decode(SharedStore.encode(payload)) == payload)
    }
}
