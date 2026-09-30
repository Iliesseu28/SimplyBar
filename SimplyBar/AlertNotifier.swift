import AppKit
import Observation
import UserNotifications

/// Sends the alerts as local notifications. Nothing touches the notification center before `activate()`, which the
/// monitor calls at launch; permission is asked the first time the user turns an alert on, never before.
@MainActor
@Observable
final class AlertNotifier {
    /// Nil until read, and in the screenshot renderer, which never activates it.
    private(set) var status: UNAuthorizationStatus?

    @ObservationIgnored private var active = false
    @ObservationIgnored private let presenter = BannerPresenter()

    var canNotify: Bool { status == .authorized || status == .provisional }

    func activate() {
        active = true
        UNUserNotificationCenter.current().delegate = presenter
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        guard active else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if status != self.status { self.status = status }
    }

    /// Shows the macOS prompt the first time; afterwards it only reads the answer again.
    func requestAuthorization() async {
        guard active else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            SystemMonitor.log.error("Notification permission failed: \((error as NSError).code, privacy: .public)")
        }
        await refreshStatus()
    }

    /// The notification settings of SimplyBar in System Settings, where a refusal is undone.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "fr.simplibot.simplybar"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ alert: Alert) {
        guard active, canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.title(alert)
        content.body = Self.body(alert)
        content.sound = .default
        // One notification per object: a newer one replaces the older in Notification Center.
        let request = UNNotificationRequest(identifier: Self.identifier(alert), content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                SystemMonitor.log.notice("Alert sent: \(alert.kind.rawValue, privacy: .public)")
            } catch {
                SystemMonitor.log.error("Alert not sent: \((error as NSError).code, privacy: .public)")
            }
        }
    }

    // MARK: - Text

    static func title(_ alert: Alert) -> String {
        switch alert {
        case .bluetoothBattery: String(localized: "Bluetooth battery low")
        case .diskSpace: String(localized: "Startup disk almost full")
        case .heat(let level): level == .critical ? String(localized: "Your Mac is very hot") : String(localized: "Your Mac is hot")
        }
    }

    static func body(_ alert: Alert) -> String {
        switch alert {
        case .bluetoothBattery(let device, let percent):
            let left = Format.percent(Double(percent) / 100)
            return String(localized: "\(device): \(left) left.", comment: "Bluetooth device name, then its battery level.")
        case .diskSpace(let free, _):
            let amount = "\(Format.diskGigabytes(free, decimals: 1)) \(String(localized: "GB"))"
            return String(localized: "Only \(amount) free on the startup disk.", comment: "Free space with its unit.")
        case .heat(let level):
            return level.advice.map { String(localized: $0) } ?? ""
        }
    }

    private static func identifier(_ alert: Alert) -> String {
        switch alert {
        case .bluetoothBattery(let device, _): "\(alert.kind.rawValue).\(device)"
        case .diskSpace, .heat: alert.kind.rawValue
        }
    }
}

/// Shows the banner even while SimplyBar is the active app (its settings window in front); macOS hides it otherwise.
private final class BannerPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
