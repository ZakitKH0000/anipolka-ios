import SwiftUI

/// Catalogue answers kept on the iPhone for a while: details and similar titles for a week, shelves for six hours.
@MainActor final class CatalogCache {
    static let shared = CatalogCache()
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AniPolka-catalog", isDirectory: true)
    func load<T: Decodable>(_ type: T.Type, key: String, maxAge: TimeInterval) -> T? {
        let url = folder.appendingPathComponent(key + ".json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let date = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < maxAge, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func save<T: Encodable>(_ value: T, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: folder.appendingPathComponent(key + ".json"), options: .atomic) }
    }
}

extension NetworkService {
    func details(_ id: Int) async throws -> AnimeDetails? {
        if let cached = CatalogCache.shared.load(AnimeDetails.self, key: "details-\(id)", maxAge: 7 * 86400) { return cached }
        let value = try Catalog.parseDetails(await metadataPublic(URL(string: "https://shikimori.io/api/graphql")!, body: Catalog.detailsQuery(id)))
        if let value { CatalogCache.shared.save(value, key: "details-\(id)") }
        return value
    }
    func similar(_ id: Int) async throws -> [CatalogItem] {
        if let cached = CatalogCache.shared.load([CatalogItem].self, key: "similar-\(id)", maxAge: 7 * 86400) { return cached }
        let value = try Catalog.parseSimilar(await metadataPublic(URL(string: "https://shikimori.io/api/animes/\(id)/similar")!))
        CatalogCache.shared.save(value, key: "similar-\(id)")
        return value
    }
    func shelf(_ shelf: Catalog.Shelf) async throws -> [CatalogItem] {
        let key = "shelf-\(String(describing: shelf))"
        if let cached = CatalogCache.shared.load([CatalogItem].self, key: key, maxAge: 6 * 3600) { return cached }
        let value = try Catalog.parseItems(await metadataPublic(URL(string: "https://shikimori.io/api/graphql")!, body: Catalog.shelfQuery(shelf)))
        CatalogCache.shared.save(value, key: key)
        return value
    }
    func catalogSearch(_ text: String) async throws -> [CatalogItem] {
        try Catalog.parseItems(await metadataPublic(URL(string: "https://shikimori.io/api/graphql")!, body: Catalog.searchQuery(text)))
    }
}

/// Plot, genres, studio, score, trailers, screenshots and similar titles on the title card.
struct AnimeInfoSection: View {
    let entry: Entry
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var store: ShelfStore
    @State private var details: AnimeDetails?
    @State private var similar: [CatalogItem] = []
    @State private var expanded = false
    @State private var previewing: CatalogItem?
    @State private var fullScreenshot: String?
    var body: some View {
        Group {
            if let d = details {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        if let score = d.score { Label(String(format: "%.1f", score), systemImage: "star.fill").foregroundStyle(.yellow) }
                        if let rating = d.ratingLabel { Text(rating).padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary)) }
                        if let minutes = d.duration { Label("\(minutes) мин", systemImage: "clock") }
                        if let studio = d.studios.first { Label(studio, systemImage: "building.2").lineLimit(1) }
                    }.font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    if !d.genres.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(d.genres, id: \.self) { Text($0).font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(Color.secondary.opacity(0.15), in: Capsule()) } }
                        }
                    }
                    if !d.description.isEmpty {
                        Text(d.description).font(.subheadline).lineLimit(expanded ? nil : 4).textSelection(.enabled)
                        Button(expanded ? "Свернуть" : "Читать полностью") { withAnimation(.snappy) { expanded.toggle() } }.font(.footnote.weight(.semibold))
                    }
                    if !d.screenshots.isEmpty {
                        Text("Кадры").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(d.screenshots.enumerated()), id: \.offset) { index, url in
                                    Button { fullScreenshot = d.screenshotsFull.indices.contains(index) ? d.screenshotsFull[index] : url } label: {
                                        CoverView(data: nil, url: url).frame(width: 200, height: 112).clipShape(RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !d.videos.isEmpty {
                        Text("Видео").font(.headline)
                        ForEach(d.videos.prefix(6)) { video in
                            if let url = URL(string: video.url) {
                                Link(destination: url) {
                                    HStack { Image(systemName: "play.rectangle.fill").font(.title3); Text(video.title).font(.subheadline); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Похожее").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) { ForEach(similar) { item in Button { previewing = item } label: { CatalogPoster(item: item, width: 110) }.buttonStyle(.plain) } }
                    }
                }
            }
        }
        .task(id: entry.sourceID) {
            guard let id = entry.sourceID else { return }
            details = try? await network.details(id)
            similar = (try? await network.similar(id)) ?? []
        }
        .sheet(item: $previewing) { item in CatalogPreview(item: item).environmentObject(store).environmentObject(network) }
        .sheet(item: Binding(get: { fullScreenshot.map { ShotURL(url: $0) } }, set: { fullScreenshot = $0?.url })) { shot in
            ZStack { Color.black.ignoresSafeArea(); CoverView(data: nil, url: shot.url).aspectRatio(16/9, contentMode: .fit) }.presentationDetents([.medium, .large])
        }
    }
}
private struct ShotURL: Identifiable { let url: String; var id: String { url } }

struct CatalogPoster: View {
    let item: CatalogItem
    var width: CGFloat = 120
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverView(data: nil, url: item.posterURL).frame(width: width, height: width * 1.45).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    if store.snapshot.entries.contains(where: { $0.sourceID == item.id }) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).font(.title3).padding(6)
                    }
                }
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true).frame(width: width, alignment: .leading)
            if let score = item.score { Text("★ " + String(format: "%.1f", score)).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// A catalogue title before adding it: poster, details and «Смотрю» / «На потом».
struct CatalogPreview: View {
    let item: CatalogItem
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var network: NetworkService
    @Environment(\.dismiss) private var dismiss
    @State private var details: AnimeDetails?
    @State private var opened: UUID?
    private var existing: Entry? { store.snapshot.entries.first { $0.sourceID == item.id } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        CoverView(data: nil, url: item.posterURL).frame(width: 120, height: 174).clipShape(RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.title3.bold())
                            if item.originalTitle != item.title { Text(item.originalTitle).font(.subheadline).foregroundStyle(.secondary) }
                            Text(item.line).font(.footnote).foregroundStyle(.secondary)
                            if let d = details, let studio = d.studios.first { Text(studio).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if let existing {
                        Button { opened = existing.id } label: { Label("Уже в коллекции · открыть", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
                    } else {
                        HStack {
                            Button { add(.watching) } label: { Label("Смотрю", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
                            Button { add(.planned) } label: { Label("На потом", systemImage: "bookmark").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
                        }.accessibilityIdentifier("catalog-add")
                    }
                    if let d = details {
                        if !d.genres.isEmpty { Text(d.genres.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
                        if !d.description.isEmpty { Text(d.description).font(.subheadline).textSelection(.enabled) }
                        if let first = d.videos.first(where: { $0.kind == "pv" }) ?? d.videos.first, let url = URL(string: first.url) {
                            Link(destination: url) { Label(first.title, systemImage: "play.rectangle.fill") }
                        }
                    } else { ProgressView().frame(maxWidth: .infinity) }
                }.padding(20)
            }
            .navigationTitle("Каталог").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .navigationDestination(item: $opened) { id in EntryDetail(id: id) }
            .task { details = try? await network.details(item.id) }
        }
    }
    private func add(_ status: WatchStatus) {
        let entry = item.entry(status: status)
        if store.change({ $0.entries.insert(entry, at: 0) }) { opened = entry.id }
    }
}

/// «Обзор»: catalogue shelves and search, adding in one tap.
struct ExploreView: View {
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var store: ShelfStore
    @State private var shelves: [Catalog.Shelf: [CatalogItem]] = [:]
    @State private var query = ""
    @State private var results: [CatalogItem]?
    @State private var searching = false
    @State private var previewing: CatalogItem?
    @State private var problem: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let results {
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 16) {
                        ForEach(results) { item in Button { previewing = item } label: { CatalogPoster(item: item, width: 110) }.buttonStyle(.plain) }
                    }.padding(.horizontal, 20)
                } else {
                    ForEach(Catalog.Shelf.allCases) { shelf in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(shelf.rawValue).font(.title3.bold()).padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    if let items = shelves[shelf] {
                                        ForEach(items) { item in Button { previewing = item } label: { CatalogPoster(item: item) }.buttonStyle(.plain) }
                                    } else {
                                        ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)).frame(width: 120, height: 174) }
                                    }
                                }.padding(.horizontal, 20)
                            }
                        }
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20) }
                    Text("Каталог и изображения: Shikimori. Отправляются только запросы поиска.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
            }.padding(.vertical, 12)
        }
        .navigationTitle("Обзор").feedbackScreen("Обзор")
        .searchable(text: $query, prompt: "Найти аниме или дунхуа")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, value in if value.trimmingCharacters(in: .whitespaces).isEmpty { results = nil } }
        .overlay { if searching { ProgressView() } }
        .task { await loadShelves() }
        .refreshable { await loadShelves() }
        .sheet(item: $previewing) { item in CatalogPreview(item: item).environmentObject(store).environmentObject(network) }
    }
    private func loadShelves() async {
        for shelf in Catalog.Shelf.allCases where shelves[shelf] == nil {
            do { shelves[shelf] = try await network.shelf(shelf) } catch { problem = error.localizedDescription }
        }
    }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = nil; return }
        searching = true; defer { searching = false }
        results = (try? await network.catalogSearch(text)) ?? []
    }
}

/// «Сегодня»: what came out, what to continue, what airs today and soon.
struct TodayView: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let s = store.snapshot
        let fresh = s.entries.filter { e in (e.releaseNotices ?? []).contains { !$0.read } || Backlog.available(e) != nil || Airing.aired(e) != nil }
            .filter { $0.status == .watching || $0.status == .planned }
        let today = Airing.calendar(s.entries).first?.items ?? []
        let continuing = ReleasePlanner.continuing(s.entries, limit: 6).filter { e in !fresh.contains { $0.id == e.id } }
        let plans = s.entries.compactMap { e in Franchise.catchUp(e, in: s).map { (e, $0) } }.prefix(3)
        let soon = s.entries.compactMap { e -> (Entry, SequelHint)? in
            guard let hint = Airing.sequelSuggestion(e, in: s) else { return nil }
            return (e, hint)
        }.prefix(4)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst).font(.subheadline).foregroundStyle(.secondary)
                    Text(fresh.isEmpty && today.isEmpty ? "Сегодня спокойный день" : "Есть что посмотреть").font(.title2.bold())
                }.listRowBackground(Color.clear)
            }
            if !fresh.isEmpty {
                Section("Вышло новое") { ForEach(fresh) { e in TodayRow2(entry: e, detail: newLine(e)) } }
            }
            if !today.isEmpty {
                Section("Выходит сегодня") {
                    ForEach(today) { item in
                        TodayRow2(entry: item.entry, detail: item.at.map { "Серия \(item.episode ?? 0) · \($0.formatted(date: .omitted, time: .shortened)) · \(Airing.countdown($0))" } ?? "По вашему расписанию")
                    }
                }
            }
            if !continuing.isEmpty {
                Section("Продолжить") { ForEach(continuing) { e in TodayRow2(entry: e, detail: "Следующая — серия \(e.seasonEpisode + 1)") } }
            }
            if !plans.isEmpty {
                Section("Догнать к выходу") {
                    ForEach(Array(plans), id: \.0.id) { e, plan in TodayRow2(entry: e, detail: "До «\(plan.target)» \(plan.days) дн. · по \(plan.perDay) в день") }
                }
            }
            if !soon.isEmpty {
                Section("Продолжения") { ForEach(Array(soon), id: \.0.id) { e, hint in SequelRow(entry: e, hint: hint) } }
            }
            if fresh.isEmpty && today.isEmpty && continuing.isEmpty {
                ContentUnavailableView("Пока пусто", systemImage: "sun.max", description: Text("Добавьте истории в коллекцию или найдите новые во вкладке «Обзор»."))
            }
        }
        .navigationTitle("Сегодня").feedbackScreen("Сегодня")
    }
    private func newLine(_ e: Entry) -> String {
        if let n = (e.releaseNotices ?? []).filter({ !$0.read }).map(\.episode).max() { return "Серия \(n) · новая в источнике" }
        if let n = Backlog.available(e) { return "Доступно ещё \(n) \(episodesWord(n))" }
        if let n = Airing.aired(e) { return "Вышло и не просмотрено: \(n) \(episodesWord(n))" }
        return ""
    }
}

private struct TodayRow2: View {
    let entry: Entry
    let detail: String
    @AppStorage(Lab.inAppPlayer) private var inAppPlayer = true
    @State private var watching: Int?
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { EntryDetail(id: entry.id) } label: {
                HStack(spacing: 12) {
                    CoverView(data: entry.coverData, url: entry.coverURL, entryID: entry.id).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if inAppPlayer, WatchTarget.available(entry) {
                Button { watching = entry.seasonEpisode + 1 } label: { Image(systemName: "play.circle.fill").font(.title) }.buttonStyle(.borderless).accessibilityLabel("Смотреть")
            }
        }
        .fullScreenCover(item: Binding(get: { watching.map { WatchEpisode(number: $0) } }, set: { watching = $0?.number })) { item in
            WatchView(entryID: entry.id, episode: item.number).environmentObject(store)
        }
    }
}
