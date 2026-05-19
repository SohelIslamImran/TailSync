import Foundation
import UserNotifications

final class NotificationClient: @unchecked Sendable {
    private var failureNotificationDates: [String: Date] = [:]
    private let minimumNotificationInterval: TimeInterval = 60 * 60

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    func notifyFailure(filename: String, reason: String) async {
        let key = "failure:\(reason)"
        guard shouldSendNotification(for: key) else { return }
        let content = UNMutableNotificationContent()
        content.title = "TailSync transfer failed"
        content.body = "\(filename): \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "transfer-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    func notifyDeviceUnavailable(deviceName: String, reason: String) async {
        let key = "device:\(deviceName)"
        guard shouldSendNotification(for: key) else { return }
        let content = UNMutableNotificationContent()
        content.title = "TailSync device unavailable"
        content.body = "\(deviceName) cannot receive files right now. \(reason)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "device-unavailable-\(deviceName)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    private func shouldSendNotification(for key: String) -> Bool {
        let now = Date()
        if let lastDate = failureNotificationDates[key],
           now.timeIntervalSince(lastDate) < minimumNotificationInterval {
            return false
        }
        failureNotificationDates[key] = now
        return true
    }
}
