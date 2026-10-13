import AppKit
import OSLog
import StoreKit

/// Asks for an App Store rating on the launches chosen by `ReviewSchedule`, never at the very first one.
@MainActor
enum ReviewPrompt {
    /// Leaves the user a moment with the app before the prompt.
    private static let delay: Duration = .seconds(60)
    private static let logger = Logger(subsystem: "fr.simplibot.simplybar", category: "review")

    static func appDidLaunch(defaults: UserDefaults = .standard) {
        let launch = LaunchCounter(defaults: defaults).recordLaunch()
        guard ReviewSchedule.asksForReview(atLaunch: launch) else { return }
        logger.notice("Review request planned launch=\(launch)")
        Task {
            try? await Task.sleep(for: delay)
            // A menu bar app is never active on its own: without this the prompt would stay behind other windows.
            NSApp.activate()
            SKStoreReviewController.requestReview()
        }
    }
}
