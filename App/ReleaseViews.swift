import SwiftUI

struct EntrySourcesView: View {
    let entryID: UUID
    var initialAddress: String? = nil
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @Environment(\.dismiss) var dismiss
    @State private var address = ""
    @State private var page: SourcePage?
    @State private var loading = false
    @State private var message: String?
    @State private var removing: UUID?
    @State private var suggestions: [AnivibeCatalog.Page]?
    @State private var searching = false
    @State private var channel = ""
    @State private var keyword = ""
    @State private var telegramPage: SourcePage?
    @State private var telegramLoading = false
    @State private var telegramMessage: String?
    private var entry: Entry? { store.snapshot.entries.first(where:{$0.id == entryID}) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://anivibe.pro/anime/…",text:$address,axis:.vertical).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("source-url")
                    Button("Проверить страницу AniVibe") { load() }.disabled(loading || address.isEmpty).accessibilityIdentifier("inspect-source")
                    Button { findPages() } label: { HStack { Label("Найти на AniVibe по названиям",systemImage:"text.magnifyingglass"); if searching { Spacer(); ProgressView() } } }
                        .disabled(searching || entry == nil).accessibilityIdentifier("find-anivibe")
                    if let suggestions {
                        if suggestions.isEmpty { Text("Страница не найдена ни по одному названию. Добавьте английское или оригинальное название в «Другие названия» либо вставьте ссылку вручную.").font(.footnote).foregroundStyle(.secondary) }
                        ForEach(suggestions) { page in
                            Button { address = page.url; self.suggestions = nil; load() } label: {
                                VStack(alignment:.leading,spacing:3) { Text(page.slugName.capitalized).foregroundStyle(.primary); Text(page.url).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if loading { ProgressView("Читаю доступные серии…") }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Добавить источник") } footer: { Text("Вставьте страницу нужного произведения с сайта. Обложка может подставиться автоматически. Название и ваш прогресс сохранятся.") }
                if let page {
                    Section {
                        Text(page.title).font(.headline)
                        if let entry, !TitleMatcher.matches(page.names + [page.title],entry) {
                            Label("Названия страницы не совпали ни с одним названием этой истории. Проверьте, что это то же произведение и нужный сезон.",systemImage:"exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("source-mismatch")
                        }
                        Text("Выберите нужные сезон и озвучку. Последняя серия на сайте не всегда использует вашу сквозную нумерацию.").font(.footnote).foregroundStyle(.secondary)
                        ForEach(Dubs.sorted(page.options,favorites:store.snapshot.preferences.favoriteDubs)) { option in
                            HStack {
                            favoriteButton(option.label)
                            Button {
                                if assistant.connect(page:page,option:option,entryID:entryID) { self.page = nil; message = "Источник подключён. Сейчас доступна серия \(option.episode). Следующие выпуски появятся во вкладке «Выходы». Для системных уведомлений включите их в Настройках АниПолки."; assistant.scheduleBackground(); assistant.queueCovers() }
                            } label: {
                                VStack(alignment:.leading,spacing:5) { Text(option.label).foregroundStyle(.primary); Text("Доступно серий: \(option.episode) · Подключить").font(.subheadline).foregroundStyle(.blue) }
                            }.disabled((entry?.subscriptions ?? []).contains(where:{$0.pageURL == page.url && $0.optionID == option.id})).accessibilityIdentifier("source-option-\(option.id)")
                            }
                        }
                    } header: { Text("Найдено на странице") }
                }
                Section {
                    TextField("@канал или ссылка t.me/канал",text:$channel).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("telegram-channel")
                    TextField("Название, как его пишет студия",text:$keyword,axis:.vertical).accessibilityIdentifier("telegram-keyword")
                    Button { loadTelegram() } label: { HStack { Label("Проверить канал",systemImage:"paperplane"); if telegramLoading { Spacer(); ProgressView() } } }
                        .disabled(telegramLoading || channel.isEmpty || keyword.trimmingCharacters(in:.whitespaces).count < 3).accessibilityIdentifier("inspect-telegram")
                    if let telegramMessage { Text(telegramMessage).font(.footnote).foregroundStyle(.secondary) }
                    if let telegramPage, let option = telegramPage.options.first {
                        Button {
                            if assistant.connect(page:telegramPage,option:option,entryID:entryID) { self.telegramPage = nil; telegramMessage = "Канал подключён: сейчас серия \(option.episode). Новые посты студии появятся во вкладке «Выходы»."; assistant.scheduleBackground() }
                        } label: {
                            VStack(alignment:.leading,spacing:4) { Text("\(telegramPage.title): найдена серия \(option.episode)").foregroundStyle(.primary); Text("Подключить как источник").font(.subheadline).foregroundStyle(.blue) }
                        }.disabled((entry?.subscriptions ?? []).contains(where:{$0.pageURL == telegramPage.url && $0.optionID == option.id})).accessibilityIdentifier("connect-telegram")
                    }
                } header: { Text("Telegram-канал студии") } footer: { Text("Приложение читает последние ~20 публичных постов канала и ищет в первых строках поста это название с номером: «Серия: 10-16», «— 8 серия». Для другого сезона укажите название с номером сезона. Telegram из вашей сети обычно открывается только с VPN.") }
                Section("Мои источники") {
                    ForEach(entry?.subscriptions ?? []) { source in
                        VStack(alignment:.leading,spacing:8) {
                            HStack {
                                favoriteButton(source.label)
                                Toggle(source.label,isOn:Binding(get:{source.enabled},set:{ value in update(source.id) { $0.enabled = value }; assistant.scheduleBackground() }))
                            }
                            if let episode = source.lastEpisode {
                                Text((source.offset ?? 0) == 0 ? "Последняя доступная: \(episode)" : "Последняя доступная: \(source.userEpisode ?? episode) по-вашему (в источнике \(episode))").font(.subheadline)
                            }
                            Picker("Роль",selection:Binding(get:{SourceRole(source.role)},set:{ role in update(source.id) { $0.role = role == .main ? nil : role.rawValue } })) {
                                ForEach(SourceRole.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented).accessibilityIdentifier("source-role-\(source.id.uuidString)")
                            Text(SourceRole(source.role).hint).font(.caption).foregroundStyle(.secondary)
                            Stepper(value:Binding(get:{source.offset ?? 0},set:{ value in update(source.id) { $0.offset = value == 0 ? nil : value } }),in:-2000...2000) {
                                VStack(alignment:.leading,spacing:2) {
                                    Text("Сдвиг номера: \(source.offset ?? 0)").font(.subheadline)
                                    if let episode = source.lastEpisode, (source.offset ?? 0) != 0 { Text("Серия \(episode) источника = ваша \(episode - (source.offset ?? 0))").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            if let episode = source.lastEpisode, let e = entry, episode - e.seasonEpisode > 50, (source.offset ?? 0) == 0 {
                                Button("Источник считает сквозь сезоны? Сдвинуть на \(episode - e.seasonEpisode)") { update(source.id) { $0.offset = episode - e.seasonEpisode } }.font(.footnote)
                            }
                            if let checked = source.lastCheckedAt { Text("Проверено: \(checked.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                            if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if let url = validWebURL(AnivibeMirror.live(source.pageURL)) { Link("Открыть источник ↗",destination:url).font(.footnote) }
                            Button("Отключить источник",role:.destructive) { removing = source.id }.font(.footnote)
                        }.padding(.vertical,4)
                    }
                }
                Section {
                    Text("Основная озвучка уведомляет о каждой серии; запасная — только если в основной этой серии ещё нет; одна серия даёт одно уведомление. Сдвиг номера нужен, если источник считает серии сквозь все сезоны.").font(.footnote).foregroundStyle(.secondary)
                    Text("Проверяется наличие серий на выбранной публичной странице. Видео не скачиваются. Плеер открывается на самом сайте.").font(.footnote).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless).navigationTitle("Источники серий").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Готово") { dismiss() } }
                .onAppear {
                    if keyword.isEmpty, let title = entry?.title { keyword = title }
                    if address.isEmpty, let initialAddress { address = initialAddress }
                    if address.isEmpty {
                        if let value = entry?.watchURL, AnivibePageParser.canonicalURL(value) != nil { address = value }
                        else if let id = entry?.sourceID { address = "https://anivibe.pro/anime/\(id)" }
                    }
                }
                .confirmationDialog("Отключить этот источник?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing = nil}}),titleVisibility:.visible) {
                    Button("Отключить",role:.destructive) { if let id = removing { _ = store.change { state in guard let i = state.entries.firstIndex(where:{$0.id == entryID}) else { return }; state.entries[i].subscriptions?.removeAll(where:{$0.id == id}) }; removing = nil; assistant.scheduleBackground() } }
                } message: { Text("Коллекция, просмотренный прогресс и уже найденные выпуски сохранятся.") }
        }
    }
    private func update(_ id: UUID,_ change: (inout ReleaseSubscription)->Void) {
        _ = store.change { state in guard let i = state.entries.firstIndex(where:{$0.id == entryID}), let j = state.entries[i].subscriptions?.firstIndex(where:{$0.id == id}) else { return }; change(&state.entries[i].subscriptions![j]) }
    }
    /// Star a dubbing team: its tracks come first on every page, and the collection can be filtered by it.
    private func favoriteButton(_ label: String) -> some View {
        let name = Dubs.name(fromLabel:label)
        let favorite = Dubs.isFavorite(name,in:store.snapshot.preferences.favoriteDubs)
        return Button { _ = store.change { $0.preferences.favoriteDubs = Dubs.toggled(name,in:$0.preferences.favoriteDubs) } } label: {
            Image(systemName:favorite ? "star.fill" : "star").foregroundStyle(.yellow).frame(width:36,height:44)
        }.accessibilityLabel(favorite ? "Убрать «\(name)» из любимых озвучек" : "Добавить «\(name)» в любимые озвучки")
    }
    private func findPages() {
        guard let entry else { return }
        searching = true; suggestions = nil
        Task { defer { searching = false }; do { suggestions = try await assistant.anivibeCandidates(for:entry) } catch { message = error.localizedDescription } }
    }
    private func loadTelegram() {
        telegramLoading = true; telegramMessage = nil; telegramPage = nil
        let name = TelegramChannel.channel(of:channel).map { "@" + $0 } ?? channel
        Task { defer { telegramLoading = false }; do { telegramPage = try await assistant.readTelegram(channel,keyword:keyword,label:"\(name) · Telegram") } catch { telegramMessage = error.localizedDescription } }
    }
    private func load() {
        loading = true; message = nil; page = nil
        Task { defer { loading = false }; do { page = try await assistant.readPage(address) } catch { message = error.localizedDescription } }
    }
}

/// «Адрес AniVibe»: when the site moves to a mirror, every page is read there; saved links do not change.
struct AnivibeMirrorSection: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var network: NetworkService
    @State private var text = ""
    @State private var checking = false
    @State private var result: String?
    var body: some View {
        Section {
            TextField(AnivibeMirror.defaultHost, text: $text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("anivibe-host")
            HStack {
                Button("Сохранить") { save() }.disabled(AnivibeMirror.normalizedHost(text) == nil || AnivibeMirror.normalizedHost(text) == (store.snapshot.preferences.anivibeHost ?? AnivibeMirror.defaultHost))
                Spacer()
                if store.snapshot.preferences.anivibeHost != nil { Button("Вернуть anivibe.pro") { text = ""; result = nil; _ = store.change { $0.preferences.anivibeHost = nil } } }
            }.buttonStyle(.borderless)
            Button { Task { await check() } } label: { HStack { Label("Проверить адрес", systemImage: "network"); if checking { Spacer(); ProgressView() } } }.disabled(checking)
            if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Адрес AniVibe") } footer: {
            Text("Сейчас: \(store.snapshot.preferences.anivibeHost ?? AnivibeMirror.defaultHost). Если сайт переедет на зеркало, впишите новый адрес — все подключённые страницы будут читаться с него, а сохранённые ссылки останутся прежними.")
        }
        .onAppear { if text.isEmpty { text = store.snapshot.preferences.anivibeHost ?? "" } }
    }
    private func save() {
        guard let host = AnivibeMirror.normalizedHost(text) else { return }
        _ = store.change { $0.preferences.anivibeHost = host == AnivibeMirror.defaultHost ? nil : host }
        text = host; result = "Сохранено. Нажмите «Проверить адрес»."
    }
    /// Reads one connected page (or the site map) through the address in use.
    private func check() async {
        checking = true; defer { checking = false }
        let page = store.snapshot.entries.flatMap { $0.subscriptions ?? [] }.first { AnivibePageParser.canonicalURL($0.pageURL) != nil }
        do {
            if let page, let url = AnivibePageParser.canonicalURL(page.pageURL) {
                let html = try await network.sourcePage(url)
                let parsed = try AnivibePageParser.parse(html, url: url.absoluteString)
                result = "Работает: \(AnivibeMirror.host) отдал страницу «\(parsed.title)» (\(parsed.options.count) озвучек)."
            } else {
                _ = try await network.anivibeSitemap(AnivibeCatalog.sitemapIndex)
                result = "Работает: \(AnivibeMirror.host) отвечает."
            }
        } catch { result = "Не работает: \(error.localizedDescription)" }
    }
}
