import SwiftUI
import UserNotifications

@MainActor final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()
    static let releaseCategory = "release"
    static let markAction = "mark-watched"
    private var digestSignature: String?
    private var premiereSignature: String?
    func enable() async -> Bool { (try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge])) ?? false }
    func registerCategories() {
        let mark = UNNotificationAction(identifier:Self.markAction,title:"+1 · Отметить серию просмотренной",options:[])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier:Self.releaseCategory,actions:[mark],intentIdentifiers:[])])
    }
    func deliver(_ notice: ReleaseNotice,entryID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "Новая серия · \(notice.title)"
        content.body = "AniVibe · \(notice.sourceLabel ?? "Выбранная дорожка"): серия \(notice.episode). Нажмите, чтобы открыть просмотр."
        content.sound = .default; content.categoryIdentifier = Self.releaseCategory
        content.userInfo = ["watchURL":notice.url,"entryID":entryID.uuidString,"noticeID":notice.id]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:notice.id,content:content,trigger:nil))
    }
    /// One repeating local reminder per weekday that has titles in the user's own schedule.
    /// Needs no network: iOS delivers it on time even when the app is closed.
    func scheduleDigest(_ snapshot: Snapshot) {
        let prefs = snapshot.preferences
        let plan: [(Int,[String])] = prefs.dailyDigest ? ReleasePlanner.displayOrder.map { day in (day,ReleasePlanner.due(snapshot.entries,weekday:day).map(\.title)) }.filter { !$0.1.isEmpty } : []
        let signature = "\(prefs.digestMinutes)|" + plan.map { "\($0.0):\($0.1.joined(separator:"\n"))" }.joined(separator:"|")
        guard signature != digestSignature else { return }
        digestSignature = signature
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:(1...7).map { "digest-\($0)" })
        for (day,titles) in plan {
            let content = UNMutableNotificationContent()
            content.title = titles.count == 1 ? "Сегодня выходит новая серия" : "Сегодня выходят новые серии"
            content.body = ReleasePlanner.digestBody(titles); content.sound = .default
            var when = DateComponents(); when.weekday = day; when.hour = prefs.digestMinutes / 60; when.minute = prefs.digestMinutes % 60
            center.add(UNNotificationRequest(identifier:"digest-\(day)",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:when,repeats:true)))
        }
    }
    /// One reminder at 10:00 on the premiere day of each upcoming title.
    func schedulePremieres(_ snapshot: Snapshot) {
        let upcoming = PremierePlanner.upcoming(snapshot.entries).prefix(50)
        let signature = upcoming.map { "\($0.id)|\($0.title)|\($0.premiereDate!.timeIntervalSince1970)" }.joined(separator:"\n")
        guard signature != premiereSignature else { return }
        premiereSignature = signature
        let center = UNUserNotificationCenter.current()
        Task {
            let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("premiere-") }
            center.removePendingNotificationRequests(withIdentifiers:stale)
            for entry in upcoming {
                var when = Calendar.current.dateComponents([.year,.month,.day],from:entry.premiereDate!)
                when.hour = PremierePlanner.reminderHour
                guard let fire = Calendar.current.date(from:when), fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Сегодня премьера"; content.body = "«\(entry.title)» — пора смотреть первую серию."; content.sound = .default
                try? await center.add(UNNotificationRequest(identifier:"premiere-\(entry.id.uuidString)",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:when,repeats:false)))
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.sound,.list] }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == Self.markAction {
            guard let raw = info["entryID"] as? String, let id = UUID(uuidString:raw) else { return }
            let store = ShelfStore.shared
            guard store.increment(id:id) != nil, let noticeID = info["noticeID"] as? String else { return }
            _ = store.change { state in
                guard let i = state.entries.firstIndex(where:{$0.id == id}), let j = state.entries[i].releaseNotices?.firstIndex(where:{$0.id == noticeID}) else { return }
                state.entries[i].releaseNotices?[j].read = true
            }
            return
        }
        guard let address = info["watchURL"] as? String, AnivibePageParser.canonicalURL(address) != nil, let url = URL(string:address) else { return }
        await UIApplication.shared.open(url)
    }
}
