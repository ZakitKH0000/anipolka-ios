import SwiftUI

struct ReleasesView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    private var notices: [(UUID,ReleaseNotice)] { store.snapshot.entries.flatMap { e in (e.releaseNotices ?? []).map { (e.id,$0) } }.sorted { $0.1.foundAt > $1.1.foundAt } }
    var body: some View {
        List {
            Section {
                if store.demo { Text("Предпросмотр: тестовые история, озвучка и новый выпуск.").font(.caption).foregroundStyle(.secondary) }
                Button { Task { await assistant.checkReleases() } } label: {
                    HStack { Label("Проверить сейчас",systemImage:"arrow.clockwise"); if assistant.checking { Spacer(); ProgressView() } }
                }.disabled(assistant.checking).accessibilityIdentifier("check-releases")
                if let message = assistant.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Фоновое обновление запускает iOS. Проверки могут задерживаться, особенно после принудительного закрытия приложения или в режиме энергосбережения.") }
            if notices.isEmpty {
                Section {
                    ContentUnavailableView("Новые серии появятся здесь",systemImage:"play.rectangle.on.rectangle",description:Text("Откройте историю → «Источники новых серий» и выберите страницу, сезон и озвучку AniVibe."))
                }
            } else {
                Section("Найденные выпуски") {
                    ForEach(notices,id:\.1.id) { entryID, notice in
                        VStack(alignment:.leading,spacing:8) {
                            HStack(alignment:.top) { Text(notice.title).font(.headline); if !notice.read { Circle().fill(.blue).frame(width:8,height:8).accessibilityLabel("Не прочитано") } }
                            Text(notice.episode - notice.previousEpisode > 1 ? "Новые серии: \(notice.previousEpisode + 1)–\(notice.episode)" : "Новая серия: \(notice.episode)")
                            Text(notice.foundAt,style:.date).font(.caption).foregroundStyle(.secondary)
                            if let url = validWebURL(notice.url) { Link("Открыть просмотр ↗",destination:url).simultaneousGesture(TapGesture().onEnded { markRead(entryID:entryID,id:notice.id) }) }
                            NavigationLink("Карточка произведения") { EntryDetail(id:entryID) }.font(.footnote).accessibilityIdentifier("release-entry")
                        }.padding(.vertical,6)
                            .swipeActions { Button("Прочитано") { markRead(entryID:entryID,id:notice.id) }.tint(.blue) }
                    }
                }
            }
            Section("Подключённые истории") {
                ForEach(store.snapshot.entries.filter { !($0.subscriptions ?? []).isEmpty }) { entry in
                    NavigationLink { EntryDetail(id:entry.id) } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(entry.title)
                            Text("Источников: \((entry.subscriptions ?? []).count)").font(.caption).foregroundStyle(.secondary)
                            if (entry.subscriptions ?? []).contains(where:{$0.error != nil}) { Label("Есть недоступный источник",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            }
        }.navigationTitle("Новые серии").refreshable { await assistant.checkReleases() }
    }
    private func markRead(entryID: UUID,id: String) {
        _ = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entryID}), let j = state.entries[i].releaseNotices?.firstIndex(where:{$0.id == id}) else { return }
            state.entries[i].releaseNotices?[j].read = true
        }
    }
}

struct EntrySourcesView: View {
    let entryID: UUID
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @Environment(\.dismiss) var dismiss
    @State private var address = ""
    @State private var page: SourcePage?
    @State private var loading = false
    @State private var message: String?
    @State private var removing: UUID?
    private var entry: Entry? { store.snapshot.entries.first(where:{$0.id == entryID}) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://anivibe.pro/anime/…",text:$address,axis:.vertical).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("source-url")
                    Button("Проверить страницу AniVibe") { load() }.disabled(loading || address.isEmpty).accessibilityIdentifier("inspect-source")
                    if loading { ProgressView("Читаю доступные серии…") }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Добавить источник") } footer: { Text("Вставьте страницу нужного произведения с сайта. Обложка может подставиться автоматически. Название и ваш прогресс сохранятся.") }
                if let page {
                    Section {
                        Text(page.title).font(.headline)
                        Text("Выберите нужные сезон и озвучку. Последняя серия на сайте не всегда использует вашу сквозную нумерацию.").font(.footnote).foregroundStyle(.secondary)
                        ForEach(page.options) { option in
                            Button {
                                if assistant.connect(page:page,option:option,entryID:entryID) { self.page = nil; message = "Источник подключён. Сейчас доступна серия \(option.episode). Уведомления начнутся со следующих новых серий."; assistant.scheduleBackground(); assistant.queueCovers() }
                            } label: {
                                VStack(alignment:.leading,spacing:5) { Text(option.label).foregroundStyle(.primary); Text("Доступно серий: \(option.episode) · Подключить").font(.subheadline).foregroundStyle(.blue) }
                            }.disabled((entry?.subscriptions ?? []).contains(where:{$0.pageURL == page.url && $0.optionID == option.id})).accessibilityIdentifier("source-option-\(option.id)")
                        }
                    } header: { Text("Найдено на странице") }
                }
                Section("Мои источники") {
                    ForEach(entry?.subscriptions ?? []) { source in
                        VStack(alignment:.leading,spacing:8) {
                            Toggle(source.label,isOn:Binding(get:{source.enabled},set:{ value in update(source.id) { $0.enabled = value }; assistant.scheduleBackground() }))
                            if let episode = source.lastEpisode { Text("Последняя доступная: \(episode)").font(.subheadline) }
                            if let checked = source.lastCheckedAt { Text("Проверено: \(checked.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(.secondary) }
                            if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if let url = validWebURL(source.pageURL) { Link("Открыть источник ↗",destination:url).font(.footnote) }
                            Button("Отключить источник",role:.destructive) { removing = source.id }.font(.footnote)
                        }.padding(.vertical,4)
                    }
                }
                Section {
                    Text("VK: подключение требует регистрации приложения VK ID и разрешённого доступа к API публикаций/видео. В этой версии автоматическая проверка VK не подключена.").font(.footnote).foregroundStyle(.secondary)
                    Text("Проверяется наличие серий на выбранной публичной странице. Видео не скачиваются. Плеер открывается на самом сайте.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Источники серий").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Готово") { dismiss() } }
                .onAppear {
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
    private func load() {
        loading = true; message = nil; page = nil
        Task { defer { loading = false }; do { page = try await assistant.readPage(address) } catch { message = error.localizedDescription } }
    }
}
