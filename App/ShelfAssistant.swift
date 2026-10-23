import SwiftUI
import BackgroundTasks
import UserNotifications

@MainActor final class ShelfAssistant: ObservableObject {
    static let refreshID = "com.zakitkh.anipolka.releases"
    @Published private(set) var checking = false
    @Published private(set) var findingCovers = false
    @Published var message: String?
    private let store: ShelfStore
    private let network: NetworkService
    private var coverTask: Task<Void,Never>?
    private var coverAttempts: [UUID:Date] = [:]
    init(store: ShelfStore, network: NetworkService) { self.store = store; self.network = network; UNUserNotificationCenter.current().delegate = NotificationBridge.shared }

    func queueCovers(force: Bool = false) {
        let previewProbe = store.demo && ProcessInfo.processInfo.arguments.contains("--live-covers")
        guard coverTask == nil, !store.demo || previewProbe, store.loadFailure == nil, network.canLoadCovers, force || store.snapshot.preferences.automaticCovers else { return }
        coverTask = Task {
            findingCovers = true
            var continueBatch = false
            defer { findingCovers = false; coverTask = nil; if continueBatch && !Task.isCancelled { queueCovers() } }
            let ids = store.snapshot.entries.filter { entry in
                guard entry.coverData == nil, entry.coverLookupDisabled != true else { return false }
                if !force, entry.coverDiscovery?.query == entry.title, let attempt = coverAttempts[entry.id], attempt.timeIntervalSinceNow > -60 { return false }
                return force || entry.coverDiscovery?.query != entry.title || (entry.coverDiscovery?.checkedAt ?? .distantPast).timeIntervalSinceNow < -86400
            }.prefix(30).map(\.id)
            continueBatch = ids.count == 30
            guard !ids.isEmpty else { return }
            for id in ids {
                guard !Task.isCancelled, force || store.snapshot.preferences.automaticCovers, network.canLoadCovers,
                      let entry = store.snapshot.entries.first(where:{$0.id == id}), entry.coverData == nil, entry.coverLookupDisabled != true else { continue }
                coverAttempts[id] = Date()
                do {
                    var address = entry.coverURL
                    if address.isEmpty {
                        let query = TitleIdentity.query(entry.title)
                        let candidates = try await network.automaticCoverCandidates(query)
                        try Task.checkCancellation()
                        guard let current = store.snapshot.entries.first(where:{$0.id == id}), current.title == entry.title, current.coverURL.isEmpty, current.coverData == nil, current.coverLookupDisabled != true else { continue }
                        if let index = TitleIdentity.uniqueExactMatch(query:query,candidates:candidates.map { [$0.title,$0.name] }) {
                            let candidate = candidates[index]; address = candidate.posterURL
                            guard !address.isEmpty else { setDiscovery(id:id,title:entry.title,message:"Произведение найдено, но в каталоге нет обложки. Можно выбрать свою.",needsChoice:false); continue }
                            _ = store.change { state in
                                guard let i = state.entries.firstIndex(where:{$0.id == id}) else { return }
                                state.entries[i].coverURL = candidate.posterURL
                                state.entries[i].sourceID = candidate.shikimoriID; state.entries[i].sourceURL = candidate.pageURL
                                state.entries[i].originalTitle = candidate.name
                                state.entries[i].coverDiscovery = CoverDiscovery(query:entry.title,message:"Обложка найдена автоматически: \(candidate.title)",needsChoice:false)
                            }
                        } else {
                            setDiscovery(id:id,title:entry.title,message:candidates.isEmpty ? "Обложка не найдена. Можно уточнить название или выбрать свою." : "Найдены похожие произведения. Выберите подходящую обложку.",needsChoice:!candidates.isEmpty)
                            continue
                        }
                    }
                    if !address.isEmpty {
                        let data = try await network.image(address); try Task.checkCancellation()
                        store.cacheCover(id:id,url:address,data:data)
                    }
                } catch {
                    if Task.isCancelled { return }
                    setDiscovery(id:id,title:entry.title,message:"Не удалось загрузить обложку. Можно повторить поиск.",needsChoice:false)
                }
            }
        }
    }
    private func setDiscovery(id: UUID,title: String,message: String,needsChoice: Bool) {
        _ = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == id}), state.entries[i].title == title else { return }
            state.entries[i].coverDiscovery = CoverDiscovery(query:title,message:message,needsChoice:needsChoice)
        }
    }
    func readPage(_ address: String) async throws -> SourcePage {
        guard let url = AnivibePageParser.canonicalURL(address) else { throw ShelfError.invalid("Вставьте HTTPS-ссылку на страницу произведения: anivibe.pro/anime/…") }
        let html = try await network.sourcePage(url)
        return try AnivibePageParser.parse(html,url:url.absoluteString)
    }
    func connect(page: SourcePage,option: SourceOption,entryID: UUID) -> Bool {
        store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entryID}) else { return }
            var sources = state.entries[i].subscriptions ?? []
            guard !sources.contains(where:{$0.pageURL == page.url && $0.optionID == option.id}) else { return }
            sources.append(ReleaseSubscription(pageURL:page.url,optionID:option.id,label:option.label,episode:option.episode))
            state.entries[i].subscriptions = sources
            if state.entries[i].watchURL.isEmpty { state.entries[i].watchURL = page.watchURL(for:option,episode:option.episode) }
            if state.entries[i].coverData == nil, state.entries[i].coverURL.isEmpty, state.entries[i].coverLookupDisabled != true, let cover = page.coverURL {
                state.entries[i].coverURL = cover; state.entries[i].coverLookupDisabled = false
            }
        }
    }
    func checkReleases(background: Bool = false) async {
        guard !checking, !store.demo, !background || store.snapshot.preferences.backgroundChecks else { return }
        checking = true; defer { checking = false; scheduleBackground() }
        if !background { message = nil }
        let work = store.snapshot.entries.flatMap { e in (e.subscriptions ?? []).filter(\.enabled).map { (e.id,$0.id,$0.pageURL,$0.lastCheckedAt) } }
            .sorted { ($0.3 ?? .distantPast) < ($1.3 ?? .distantPast) }
        var pages: [String:SourcePage] = [:], newCount = 0, errors = 0
        for (entryID,sourceID,url,lastChecked) in work.prefix(background ? 8 : 60) {
            if Task.isCancelled { break }
            if background, let lastChecked, lastChecked.timeIntervalSinceNow > -3600 { continue }
            do {
                let page: SourcePage
                if let cached = pages[url] { page = cached }
                else { page = try await readPage(url); pages[url] = page }
                try Task.checkCancellation()
                var found: ReleaseNotice?
                guard let current = store.snapshot.entries.first(where:{$0.id == entryID}) else { continue }
                var updated = current
                found = try ReleaseTracker.observe(page,entry:&updated,subscriptionID:sourceID)
                let committed = store.change { state in
                    guard let i = state.entries.firstIndex(where:{$0.id == entryID}) else { return }
                    // Сетевой ответ не должен затирать параллельное редактирование прогресса/заметки.
                    guard state.entries[i].subscriptions == current.subscriptions else { return }
                    state.entries[i].subscriptions = updated.subscriptions
                    state.entries[i].releaseNotices = updated.releaseNotices
                }
                if committed, let found {
                    newCount += 1
                    if store.snapshot.preferences.releaseNotifications { await NotificationBridge.shared.deliver(found) }
                }
            } catch {
                if Task.isCancelled { break }
                errors += 1
                _ = store.change { state in
                    guard let i = state.entries.firstIndex(where:{$0.id == entryID}), let j = state.entries[i].subscriptions?.firstIndex(where:{$0.id == sourceID}) else { return }
                    state.entries[i].subscriptions?[j].error = error.localizedDescription
                    state.entries[i].subscriptions?[j].lastCheckedAt = Date()
                }
            }
        }
        if !background { message = work.isEmpty ? "Выберите источник в карточке произведения." : "Проверено источников: \(min(work.count,60)). Новых выпусков: \(newCount)." + (errors > 0 ? " Недоступно: \(errors). Подробности — в карточках." : "") }
    }
    func scheduleBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:Self.refreshID)
        guard !store.demo, store.snapshot.preferences.backgroundChecks, store.snapshot.entries.contains(where:{($0.subscriptions ?? []).contains(where:\.enabled)}) else { return }
        let request = BGAppRefreshTaskRequest(identifier:Self.refreshID)
        request.earliestBeginDate = Date().addingTimeInterval(6*3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

@MainActor final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()
    func enable() async -> Bool { (try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge])) ?? false }
    func deliver(_ notice: ReleaseNotice) async {
        let content = UNMutableNotificationContent()
        content.title = "Новая серия · \(notice.title)"
        content.body = "AniVibe · \(notice.sourceLabel ?? "Выбранная дорожка"): серия \(notice.episode). Нажмите, чтобы открыть просмотр."
        content.sound = .default; content.userInfo = ["watchURL":notice.url]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:notice.id,content:content,trigger:nil))
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.sound,.list] }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse) async {
        guard let address = response.notification.request.content.userInfo["watchURL"] as? String, AnivibePageParser.canonicalURL(address) != nil, let url = URL(string:address) else { return }
        await UIApplication.shared.open(url)
    }
}
