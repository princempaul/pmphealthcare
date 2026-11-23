import Foundation
import UserNotifications

/// Local notifications for new "needs you" items. Nothing leaves the phone.
@MainActor
enum Notifier {
    private static let seenKey = "notified.ids"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Notify once per new action-level item; badge = how many need Paul.
    static func update(with items: [TowerItem]) {
        guard UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let actionable = items.filter { $0.level != .info }
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        let fresh = actionable.filter { $0.level == .action && !seen.contains($0.id) }
        for item in fresh.prefix(3) {
            let c = UNMutableNotificationContent()
            c.title = item.title
            c.body = item.detail.isEmpty ? item.source : "\(item.detail) · \(item.source)"
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: c, trigger: nil))
        }
        seen.formUnion(actionable.map(\.id))
        UserDefaults.standard.set(Array(seen.suffix(500)), forKey: seenKey)
        UNUserNotificationCenter.current().setBadgeCount(actionable.filter { $0.level == .action }.count) { _ in }
    }
}
