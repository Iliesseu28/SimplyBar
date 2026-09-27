import Foundation

/// Every address the app shows, in one place. The simplibot.fr pages below must be online before the app ships.
enum AppLinks {
    static let site = URL(string: "https://simplibot.fr/simplybar")!
    static let privacy = URL(string: "https://simplibot.fr/simplybar/confidentialite")!
    static let support = URL(string: "https://simplibot.fr/simplybar/support")!
    static let contactEmail = "contact@simplibot.fr"
    static let contact = URL(string: "mailto:contact@simplibot.fr")!
    /// Apple ID of the app, known once its App Store Connect record exists. Until then the review link is inactive.
    static let appStoreID: String? = nil

    /// The Mac App Store page of the app, opened on its review form.
    static var appStoreReview: URL? {
        appStoreID.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)?action=write-review") }
    }
}
