import SwiftUI
import BackgroundTasks
import UserNotifications

@MainActor final class ShelfAssistant: ObservableObject {
    static let refreshID = "com.zakitkh.anipolka.releases"
    @Published private(set) var checking = false
    @Published private(set) var findingCovers = false
    @Published private(set) var refreshingAiring = false
    /// What the extra sources answered on the last refresh: counts or the error text.
    @Published private(set) var sourcesReport = ""
    static var lastSourcesReport = ""
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
    /// A Telegram channel read for one title: the newest episode among the visible posts.
    func readTelegram(_ address: String, keyword: String, label: String, known: Int? = nil) async throws -> SourcePage {
        guard let url = TelegramChannel.canonicalURL(address) else { throw ShelfError.invalid("Укажите канал: @название или ссылку t.me/название.") }
        return try TelegramChannel.page(try await network.telegramPage(url), url: url.absoluteString, keyword: keyword, label: label, known: known)
    }
    func connect(page: SourcePage,option: SourceOption,entryID: UUID) -> Bool {
        store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entryID}) else { return }
            state.entries[i].attachSource(page:page,option:option)
        }
    }
    func checkReleases(background: Bool = false) async {
        guard !checking, !store.demo, !background || store.snapshot.preferences.backgroundChecks else { return }
        checking = true; defer { checking = false; scheduleBackground() }
        if !background { message = nil }
        let work = store.snapshot.entries.flatMap { e in (e.subscriptions ?? []).filter(\.enabled).map { (e.id,$0) } }
            .sorted { ($0.1.lastCheckedAt ?? .distantPast) < ($1.1.lastCheckedAt ?? .distantPast) }
        var pages: [String:SourcePage] = [:], channels: [String:String] = [:], newCount = 0, errors = 0
        for (entryID,source) in work.prefix(background ? 8 : 60) {
            let sourceID = source.id, url = source.pageURL
            if Task.isCancelled { break }
            if background, let lastChecked = source.lastCheckedAt, lastChecked.timeIntervalSinceNow > -3600 { continue }
            do {
                let page: SourcePage
                if let keyword = TelegramChannel.keyword(source.optionID) {
                    let html: String
                    if let cached = channels[url] { html = cached }
                    else { guard let channelURL = TelegramChannel.canonicalURL(url) else { continue }; html = try await network.telegramPage(channelURL); channels[url] = html }
                    page = try TelegramChannel.page(html, url: url, keyword: keyword, label: source.label, known: source.lastEpisode)
                }
                else if let cached = pages[url] { page = cached }
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
                // An episode the user already marked as watched is filed as read and does not ring.
                let unread = store.snapshot.entries.first(where:{$0.id == entryID})?.releaseNotices?.contains { $0.id == found?.id && !$0.read } == true
                if committed, let found, unread {
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
    /// Next-episode times, aired counts and continuations from Shikimori for titles whose data is stale.
    func refreshAiring(force: Bool = false) async {
        guard !refreshingAiring, !store.demo, store.loadFailure == nil, store.snapshot.preferences.catalogUpdates else { return }
        refreshingAiring = true; defer { refreshingAiring = false }
        let ids = Array(Set(store.snapshot.entries.filter { force || Airing.needsRefresh($0) }.filter { $0.status != .dropped }.compactMap(\.sourceID)))
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 50, ids.count)]); start += 50
            guard let found = try? await network.airing(ids: chunk), !found.isEmpty else { continue }
            _ = store.change { state in
                for i in state.entries.indices { if let id = state.entries[i].sourceID, let info = found[id] { state.entries[i] = Airing.apply(state.entries[i], info) } }
            }
        }
        // AniList adds exact next episodes; AniLibria adds its dub schedule.
        if force || !ids.isEmpty {
            let active = Array(Set(store.snapshot.entries.filter { ($0.status == .watching || $0.status == .planned) && $0.airing != nil }.compactMap(\.sourceID)))
            var next: [Int: AniList.Next] = [:]
            var report: [String] = []
            var position = 0
            while position < active.count {
                let chunk = Array(active[position..<min(position + 50, active.count)]); position += 50
                do { next.merge(try await network.aniList(chunk)) { a, _ in a } }
                catch { report.append("AniList: ошибка — \(error.localizedDescription)") }
            }
            if report.isEmpty { report.append("AniList: время серий для \(next.count) из \(active.count)") }
            var bangumi: [Int: BangumiInfo] = [:]
            let candidates = store.snapshot.entries.filter { e in
                guard e.status == .watching || e.status == .planned, let info = e.airing, info.status != Airing.released, let native = info.nativeTitle, !native.isEmpty else { return false }
                guard let known = info.bangumi else { return true }
                return Date().timeIntervalSince(known.checkedAt) > (known.id == 0 ? 7 * 86400 : 12 * 3600) || force
            }
            var bangumiErrors = 0
            for e in candidates.prefix(12) {
                guard let id = e.sourceID, let info = e.airing, let native = info.nativeTitle else { continue }
                do {
                    let subject: Int
                    if let known = info.bangumi?.id, known > 0 { subject = known }
                    else if let found = try await network.bangumiSubject(native: native) { subject = found }
                    else { bangumi[id] = BangumiInfo(id: 0, checkedAt: Date()); continue }
                    bangumi[id] = try await network.bangumiEpisodes(subject)
                } catch { if Task.isCancelled { break }; bangumiErrors += 1 }
            }
            if !candidates.isEmpty { report.append("Bangumi: " + (bangumiErrors > 0 ? "ошибок \(bangumiErrors), " : "") + "найдено \(bangumi.values.filter { $0.id > 0 }.count) из \(min(candidates.count, 12))") }
            var libria: [Int: LibriaInfo] = [:]
            do { libria = try await network.libriaSchedule(); report.append("AniLibria: в расписании \(libria.count), из коллекции \(active.filter { libria[$0] != nil }.count)") }
            catch { report.append("AniLibria: ошибка — \(error.localizedDescription)") }
            sourcesReport = report.joined(separator: " · "); Self.lastSourcesReport = sourcesReport
            var dubbed: [(Entry, Int)] = []
            _ = store.change { state in
                for i in state.entries.indices {
                    guard let id = state.entries[i].sourceID, let info = state.entries[i].airing else { continue }
                    let before = info.libria?.publishedEpisode
                    state.entries[i].airing = Bangumi.merge(Airing.merge(info, aniList: next[id], libria: libria[id] ?? (libria.isEmpty ? info.libria : nil)), bangumi[id] ?? info.bangumi)
                    if let now = state.entries[i].airing?.libria?.publishedEpisode, let before, now > before, now > state.entries[i].seasonEpisode { dubbed.append((state.entries[i], now)) }
                }
            }
            if store.snapshot.preferences.releaseNotifications {
                for (entry, episode) in dubbed { await NotificationBridge.shared.deliverInfo(id: "libria-\(entry.id.uuidString)-\(episode)", title: "Озвучка AniLibria · \(entry.title)", body: "Вышла серия \(episode) в озвучке AniLibria.") }
            }
        }
        // Parts of every franchise in the collection, for the season tabs and the next-season prompt.
        let keys = Array(Set(store.snapshot.entries.compactMap(\.franchise))).sorted()
        for key in keys.prefix(60) {
            let previous = store.snapshot.franchises?.first { $0.key == key }
            guard force || Franchise.needsRefresh(previous), let info = try? await network.franchise(key, previous: previous) else { continue }
            _ = store.change { state in
                var list = (state.franchises ?? []).filter { $0.key != key }
                list.append(info); state.franchises = list
            }
        }
    }
    func scheduleBackground() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:Self.refreshID)
        guard !store.demo, store.snapshot.preferences.backgroundChecks, store.snapshot.entries.contains(where:{($0.subscriptions ?? []).contains(where:\.enabled) || $0.sourceID != nil}) else { return }
        let request = BGAppRefreshTaskRequest(identifier:Self.refreshID)
        request.earliestBeginDate = Date().addingTimeInterval(6*3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
