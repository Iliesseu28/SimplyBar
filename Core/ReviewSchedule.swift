import Foundation

/// When SimplyBar asks for a rating: at the second launch, then every tenth launch after it (12, 22, 32...).
/// macOS decides whether the prompt really shows (at most three times a year per user).
nonisolated enum ReviewSchedule {
    static let firstLaunch = 2
    static let interval = 10

    static func asksForReview(atLaunch launch: Int) -> Bool {
        launch >= firstLaunch && (launch - firstLaunch) % interval == 0
    }
}

/// Counts the app's launches in UserDefaults.
nonisolated struct LaunchCounter {
    static let key = "launches.count"
    let defaults: UserDefaults

    /// Records one more launch and returns its number (1 for the very first one).
    func recordLaunch() -> Int {
        let launch = defaults.integer(forKey: Self.key) + 1
        defaults.set(launch, forKey: Self.key)
        return launch
    }
}
