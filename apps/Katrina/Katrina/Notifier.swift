import Foundation
import UserNotifications

/// Local notifications for new "needs you" items. Nothing leaves the phone.
/// Items with one clear next step carry a button, so Paul can act from the Lock Screen or his watch.
@MainActor
enum Notifier {
    private static let seenKey = "notified.ids"
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private static func payload(for action: TowerItem.Action) -> (category: String, info: [String: Any])? {
        switch action {
        case .approvePush(let machine, let mission): return ("katrina.push", ["machine": machine, "mission": mission])
        case .merge(let slug, let number): return ("katrina.merge", ["slug": slug, "number": number])
        case .rerun(let slug, let run): return ("katrina.rerun", ["slug": slug, "run": run])
        case .cleanup(let machine): return ("katrina.cleanup", ["machine": machine])
        default: return nil
        }
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
            if let p = item.primary.flatMap({ payload(for: $0.action) }) {
                c.categoryIdentifier = p.category
                c.userInfo = p.info
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: c, trigger: nil))
        }
        // Remember only what is still on the board and was either notified or already known. An item that
        // clears and comes back notifies again; one that didn't fit in this round's three gets its turn next.
        let current = Set(actionable.filter { $0.level == .action }.map(\.id))
        seen = seen.intersection(current).union(fresh.prefix(3).map(\.id))
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
        UNUserNotificationCenter.current().setBadgeCount(actionable.filter { $0.level == .action }.count) { _ in }
    }

    /// Runs the button Paul tapped, then says what happened in a second notification.
    static func perform(category: String, machine: String, mission: String, slug: String, number: Int, run: Int) async {
        let action: TowerItem.Action
        switch category {
        case "katrina.push": action = .approvePush(machine: machine, mission: mission)
        case "katrina.merge": action = .merge(slug: slug, number: number)
        case "katrina.rerun": action = .rerun(slug: slug, run: run)
        case "katrina.cleanup": action = .cleanup(machine: machine)
        default: return
        }
        let brain = BrainStore.shared, github = GitHubStore.shared
        await Dispatcher.refresh(brain: brain, github: github)
        let c = UNMutableNotificationContent()
        do {
            c.title = "Katrina"
            c.body = try await Dispatcher.perform(action, brain: brain, github: github) ?? "Nothing was done: it has changed since. Open Katrina PA."
        } catch {
            c.title = "That didn't go through"
            c.body = "\(error.localizedDescription) Open Katrina PA to try again."
            c.sound = .default
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "result-\(UUID().uuidString)", content: c, trigger: nil))
    }
}

/// Receives the tap on a notification button, including when the app was closed.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Called at launch, so a button tapped while the app is closed still finds its handler.
    static func register() {
        let buttons = [("katrina.push", "Approve & push"), ("katrina.merge", "Merge"),
                       ("katrina.rerun", "Re-run build"), ("katrina.cleanup", "Clear caches")]
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories(Set(buttons.map { category, title in
            // the phone must be unlocked first: these change code or files on the Mac
            UNNotificationCategory(identifier: category,
                                   actions: [UNNotificationAction(identifier: "do", title: title, options: [.authenticationRequired])],
                                   intentIdentifiers: [])
        }))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let content = response.notification.request.content
        guard response.actionIdentifier == "do" else { done(); return }
        let category = content.categoryIdentifier
        let machine = content.userInfo["machine"] as? String ?? ""
        let mission = content.userInfo["mission"] as? String ?? ""
        let slug = content.userInfo["slug"] as? String ?? ""
        let number = content.userInfo["number"] as? Int ?? 0
        let run = content.userInfo["run"] as? Int ?? 0
        Task { @MainActor in
            await Notifier.perform(category: category, machine: machine, mission: mission, slug: slug, number: number, run: run)
            done()
        }
    }
}
