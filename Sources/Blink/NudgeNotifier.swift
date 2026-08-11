import UserNotifications

@MainActor
enum NudgeNotifier {
    static func show() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                let content = UNMutableNotificationContent()
                content.title = "Look away"
                content.body = "Take a short break from your screens."
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                )
            }
        }
    }
}
