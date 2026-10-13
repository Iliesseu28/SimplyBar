import Foundation
import Testing

struct ReviewScheduleTests {
    @Test func asksAtSecondLaunchThenEveryTenth() {
        let asked = (1...40).filter(ReviewSchedule.asksForReview(atLaunch:))
        #expect(asked == [2, 12, 22, 32])
    }

    @Test func neverAsksAtFirstLaunch() {
        #expect(!ReviewSchedule.asksForReview(atLaunch: 1))
        #expect(!ReviewSchedule.asksForReview(atLaunch: 0))
    }

    @Test func counterStartsAtOneAndGrows() throws {
        let name = "ReviewScheduleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let counter = LaunchCounter(defaults: defaults)
        #expect(counter.recordLaunch() == 1)
        #expect(counter.recordLaunch() == 2)
        #expect(counter.recordLaunch() == 3)
    }
}
