import AppKit
import UserNotifications

/// Posts macOS notifications. Clicking one opens the Ledger window at the session.
/// Notices only tell you something happened; the recorder never blocks or pauses an agent.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    private(set) var authorized = false

    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.authorized = ok }
    }

    /// `id` replaces an earlier notice with the same id, so a repeated condition doesn't stack up.
    func post(title: String, body: String, session: String? = nil, tab: String = "summary", id: String, sound: Bool = false) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let session { content.userInfo = ["session": session, "tab": tab] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var c = URLComponents(string: "agentledger://ledger")!
        if let s = info["session"] as? String {
            c.queryItems = [URLQueryItem(name: "session", value: s), URLQueryItem(name: "tab", value: info["tab"] as? String ?? "summary")]
        }
        if let url = c.url { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    }
}
