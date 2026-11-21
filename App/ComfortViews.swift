import SwiftUI
import UniformTypeIdentifiers

// MARK: Импорт по нику

struct ListImportView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var network: NetworkService
    @Environment(\.dismiss) private var dismiss
    @State private var site: ListImport.Site = .shikimori
    @State private var nickname = ""
    @State private var items: [ListImportItem]?
    @State private var loading = false
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Сайт", selection: $site) { ForEach(ListImport.Site.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextField("Ник в профиле", text: $nickname).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await load() } }.accessibilityIdentifier("import-nickname")
                    Button { Task { await load() } } label: { HStack { Text("Загрузить список"); if loading { Spacer(); ProgressView() } } }
                        .disabled(loading || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                } footer: { Text("Пароль не нужен: читается только открытый список профиля. Уже добавленные тайтлы отмечены и не выбраны.") }
                if let items {
                    Section {
                        ForEach(items.indices, id: \.self) { i in
                            let item = items[i]
                            Toggle(isOn: Binding(get: { self.items?[i].included ?? false }, set: { self.items?[i].included = $0 })) {
                                HStack(spacing: 10) {
                                    CoverView(data: nil, url: item.posterURL).frame(width: 34, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.subheadline).lineLimit(2)
                                        Text("\(item.status.rawValue) · серия \(item.episode)" + (item.existing.map { " · уже есть: «\($0)»" } ?? "")).font(.caption).foregroundStyle(item.existing == nil ? Color.secondary : Color.blue)
                                    }
                                }
                            }
                        }
                    } header: { Text("Найдено: \(items.count)") }
                }
            }
            .navigationTitle("Импорт по нику").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    let count = items?.filter(\.included).count ?? 0
                    Button("Добавить \(count)") { add() }.disabled(count == 0).accessibilityIdentifier("import-apply")
                }
            }
        }
    }
    private func load() async {
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        loading = true; problem = nil; defer { loading = false }
        do {
            var found: [ListImportItem] = []
            switch site {
            case .shikimori:
                guard let url = ListImport.shikimoriURL(nick) else { problem = "Проверьте ник."; return }
                found = try ListImport.parseShikimori(await network.metadataPublic(url))
            case .mal:
                for page in 0..<10 {
                    guard let url = ListImport.malURL(nick, offset: page * 300) else { problem = "Проверьте ник."; return }
                    let part = try ListImport.parseMAL(await network.metadataPublic(url))
                    found += part
                    if part.count < 300 { break }
                }
            }
            items = ListImport.mark(found, in: store.snapshot)
            if found.isEmpty { problem = "Список пуст или закрыт настройками приватности." }
        } catch { problem = "Не удалось загрузить: \(error.localizedDescription)" }
    }
    private func add() {
        let chosen = (items ?? []).filter(\.included).map { $0.entry() }
        if store.change({ $0.entries.insert(contentsOf: chosen, at: 0) }) { dismiss() }
    }
}

// MARK: Дневник серий

struct DiarySection: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @State private var rating: Int?
    var body: some View {
        let diary = (entry.notes ?? []).filter(\.isDiary).sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Дневник серий").font(.headline); Spacer() }
            if entry.seasonEpisode > 0, !diary.contains(where: { $0.episode == entry.episode }) {
                HStack(spacing: 12) {
                    Text("Как серия \(entry.seasonEpisode)?").font(.subheadline)
                    Spacer()
                    ForEach(1...5, id: \.self) { star in
                        Button { rate(star) } label: { Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star").foregroundStyle(.yellow) }.buttonStyle(.borderless)
                    }
                }.accessibilityIdentifier("diary-rate")
            }
            if !diary.isEmpty {
                DisclosureGroup("Записи: \(diary.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(diary.prefix(10)) { note in
                            HStack(alignment: .top) {
                                Text("Серия \(note.episode - (entry.episodeOffset ?? 0))").font(.subheadline.weight(.semibold))
                                Text(String(repeating: "★", count: note.rating ?? 0)).foregroundStyle(.yellow)
                                if !note.text.isEmpty { Text(note.text).font(.subheadline).foregroundStyle(.secondary) }
                                Spacer()
                                Text(note.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.top, 6)
                }.font(.subheadline)
            }
            if diary.isEmpty { Text("Оцените серию звёздами — получится дневник просмотра.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private func rate(_ value: Int) {
        rating = value
        let id = entry.id, episode = entry.episode
        _ = store.change { s in if let i = s.entries.firstIndex(where: { $0.id == id }) { s.entries[i].addNote(EpisodeNote(episode: episode, rating: value)) } }
        rating = nil
    }
}

/// All diary entries, newest first.
struct DiaryFeedView: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let items = store.snapshot.entries.flatMap { e in (e.notes ?? []).filter(\.isDiary).map { (e, $0) } }.sorted { $0.1.createdAt > $1.1.createdAt }
        List {
            if items.isEmpty { ContentUnavailableView("Дневник пуст", systemImage: "book", description: Text("Оценивайте серии звёздами в карточке тайтла.")) }
            ForEach(items, id: \.1.id) { entry, note in
                NavigationLink { EntryDetail(id: entry.id) } label: {
                    HStack(spacing: 12) {
                        CoverView(data: entry.coverData, url: entry.coverURL, entryID: entry.id).frame(width: 36, height: 52).clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("Серия \(note.episode - (entry.episodeOffset ?? 0)) · " + String(repeating: "★", count: note.rating ?? 0)).font(.caption).foregroundStyle(.yellow)
                            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("Дневник просмотра")
    }
}

// MARK: Салют «Сезон досмотрен»

struct ConfettiView: View {
    private struct Piece { let x: Double; let speed: Double; let size: Double; let spin: Double; let color: Color; let delay: Double }
    private let pieces: [Piece] = (0..<90).map { _ in
        Piece(x: .random(in: 0...1), speed: .random(in: 0.25...0.6), size: .random(in: 6...12), spin: .random(in: -6...6),
              color: [.yellow, .orange, .pink, .blue, .green, .purple, .red].randomElement()!, delay: .random(in: 0...0.8))
    }
    @State private var start = Date()
    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSince(start)
                for p in pieces {
                    let time = t - p.delay
                    guard time > 0 else { continue }
                    let y = -20 + time * p.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = p.x * size.width + sin(time * 3 + p.spin) * 18
                    var piece = ctx
                    piece.translateBy(x: x, y: y); piece.rotate(by: .radians(time * p.spin))
                    piece.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false).ignoresSafeArea()
    }
}

/// «Сезон досмотрен!» with a short summary, confetti once per season and a card to share.
struct SeasonDoneCard: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @AppStorage(Lab.celebrate) private var celebrate = true
    @State private var confetti = false
    private var key: String { "celebrated-\(entry.id.uuidString)-\(entry.sourceID ?? 0)" }
    private var finished: Bool {
        guard let info = entry.airing, info.status == Airing.released, let total = info.episodes ?? info.episodesAired,
              Franchise.overflow(entry, in: store.snapshot) == nil else { return false }
        return entry.seasonEpisode >= total
    }
    private var days: Int? {
        let marks = (store.snapshot.history ?? []).filter { $0.entryID == entry.id }.map(\.at)
        guard let first = marks.min(), let last = marks.max() else { return nil }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0)
    }
    var body: some View {
        if finished {
            VStack(alignment: .leading, spacing: 8) {
                Label("Сезон досмотрен!", systemImage: "trophy.fill").font(.headline).foregroundStyle(.yellow)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                ShareLink(item: Image(uiImage: shareImage), preview: SharePreview("АниПолка · \(entry.title)", image: Image(uiImage: shareImage))) {
                    Label("Поделиться карточкой", systemImage: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { if confetti { ConfettiView().frame(height: 600).offset(y: -250) } }
            .onAppear {
                guard celebrate, !UserDefaults.standard.bool(forKey: key) else { return }
                UserDefaults.standard.set(true, forKey: key)
                confetti = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confetti = false }
            }
        }
    }
    private var summary: String {
        let total = entry.airing?.episodes ?? entry.seasonEpisode
        var text = "\(total) \(episodesWord(total))"
        if let days { text += " за \(days) \(days == 1 ? "день" : (2...4).contains(days % 10) && !(12...14).contains(days % 100) ? "дня" : "дней")" }
        if let rating = entry.rating { text += " · ваша оценка " + String(repeating: "★", count: rating) }
        return text
    }
    @MainActor private var shareImage: UIImage {
        let card = VStack(alignment: .leading, spacing: 10) {
            if let data = entry.coverData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 320, height: 200).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
            }
            Text("Сезон досмотрен!").font(.title2.bold()).foregroundStyle(.yellow)
            Text(entry.title).font(.headline).foregroundStyle(.white)
            Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Text("АниПолка").font(.caption.bold()).foregroundStyle(.white.opacity(0.6))
        }.padding(24).frame(width: 368).background(LinearGradient(colors: [Color(red: 0.08, green: 0.1, blue: 0.2), .black], startPoint: .top, endPoint: .bottom))
        let renderer = ImageRenderer(content: card); renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }
}

// MARK: Автокопия раз в неделю

/// A copy of the collection into a folder the user chose in Files, at most once a week.
@MainActor enum AutoBackup {
    static let bookmarkKey = "autoBackupFolder", lastKey = "autoBackupLast"
    static var enabled: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    static var last: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }

    static func choose(_ url: URL) -> String? {
        guard url.startAccessingSecurityScopedResource() else { return "Нет доступа к папке." }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            UserDefaults.standard.removeObject(forKey: lastKey)
            return nil
        } catch { return error.localizedDescription }
    }
    static func disable() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
    /// True when the chosen folder is in iCloud Drive, so copies outlive the app.
    static var inICloud: Bool {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        return url.path.contains("Mobile Documents")
    }

    /// Writes «АниПолка-ГГГГ-ММ-ДД.json» when a week has passed and keeps the six newest copies.
    @discardableResult static func runIfDue(_ snapshot: Snapshot, force: Bool = false) -> String? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        if !force, let last, Date().timeIntervalSince(last) < 7 * 86400 { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return "Папка для копий недоступна. Выберите её заново." }
        guard folder.startAccessingSecurityScopedResource() else { return "Нет доступа к папке для копий." }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            let data = try snapshot.encoded()
            let name = "АниПолка-" + Date().formatted(.iso8601.year().month().day()) + ".json"
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            let copies = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("АниПолка-") && $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            for old in copies.dropFirst(6) { try? FileManager.default.removeItem(at: old) }
            UserDefaults.standard.set(Date(), forKey: lastKey)
            if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
            return nil
        } catch { return "Автокопия не сохранена: \(error.localizedDescription)" }
    }
}

struct AutoBackupRow: View {
    @EnvironmentObject var store: ShelfStore
    @State private var choosing = false
    @State private var on = AutoBackup.enabled
    @State private var message: String?
    var body: some View {
        Toggle("Автокопия раз в неделю", isOn: Binding(get: { on }, set: { value in if value { choosing = true } else { AutoBackup.disable(); on = false } }))
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    message = AutoBackup.choose(url)
                    on = AutoBackup.enabled
                    if on { message = AutoBackup.runIfDue(store.snapshot, force: true) ?? "Первая копия сохранена. Дальше — раз в неделю при открытии АниПолки." }
                }
            }
        if on, let last = AutoBackup.last { Text("Последняя копия: \(last.formatted(date: .abbreviated, time: .shortened)). Хранятся шесть последних.").font(.footnote).foregroundStyle(.secondary) }
        if on, !AutoBackup.inICloud { Text("Папка не в iCloud Drive: при удалении приложения или слёте подписи копии могут пропасть. Лучше выбрать папку в iCloud Drive.").font(.footnote).foregroundStyle(.orange) }
        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
    }
}
