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
    init(store: ShelfStore, network: NetworkService) { self.store = store; self.network = network }

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
                    let result = try await network.automaticCover(entry)
                    try Task.checkCancellation()
                    guard force || store.snapshot.preferences.automaticCovers else { return }
                    switch result {
                    case .found(let cover):
                        _ = store.change { _ = $0.applyResolvedCover(cover,to:entry) }
                    case .notFound(let needsChoice):
                        setDiscovery(entry:entry,message:needsChoice ? "Найдены похожие произведения. Выберите подходящую обложку." : "В доступных каталогах настоящая обложка не найдена. Поиск можно повторить позже.",needsChoice:needsChoice)
                    }
                } catch {
                    if Task.isCancelled { return }
                    setDiscovery(entry:entry,message:"Не удалось загрузить обложку. Можно повторить поиск.",needsChoice:false)
                }
            }
        }
    }
    private func setDiscovery(entry: Entry,message: String,needsChoice: Bool) {
        _ = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entry.id}), state.entries[i].title == entry.title,
                  state.entries[i].coverURL == entry.coverURL, state.entries[i].coverData == entry.coverData,
                  state.entries[i].coverLookupDisabled != true else { return }
            state.entries[i].coverDiscovery = CoverDiscovery(query:entry.title,message:message,needsChoice:needsChoice)
        }
    }
    private var anivibePages: (loaded: Date,pages: [AnivibeCatalog.Page])?
    /// Pages whose address matches any known name of the entry. The list is cached for a day.
    func anivibeCandidates(for entry: Entry) async throws -> [AnivibeCatalog.Page] {
        if anivibePages == nil || anivibePages!.loaded.timeIntervalSinceNow < -86400 {
            let index = try await network.anivibeSitemap(AnivibeCatalog.sitemapIndex)
            var locations: [String] = []
            for file in AnivibeCatalog.sitemapFiles(in:index) {
                try Task.checkCancellation()
                locations += AnivibeCatalog.locations(in:try await network.anivibeSitemap(file))
            }
            anivibePages = (Date(),AnivibeCatalog.pages(in:locations))
        }
        return AnivibeCatalog.candidates(for:entry,in:anivibePages?.pages ?? [])
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
            state.entries[i].learnNames(page.names)
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
                    if store.snapshot.preferences.releaseNotifications { await NotificationBridge.shared.deliver(found,entryID:entryID) }
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
