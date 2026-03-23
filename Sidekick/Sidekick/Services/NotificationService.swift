import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationService: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func requestAuthorization() async {
        if ProcessInfo.processInfo.environment["SIDEKICK_QA_SKIP_NOTIFICATION_PROMPT"] == "1" {
            authorizationStatus = .denied
            return
        }

        let center = UNUserNotificationCenter.current()
        let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        if granted == true {
            return
        }
    }

    func notify(paper: Paper) {
        let content = UNMutableNotificationContent()
        content.title = "New paper"
        content.body = "\"\(paper.title)\" is ready to read."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: paper.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
