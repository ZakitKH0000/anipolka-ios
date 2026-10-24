import SwiftUI
import PhotosUI

struct EntryDetail: View {
    let id: UUID
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var editing = false
    @State private var deleteConfirmation = false
    @State private var showSources = false
    @State private var confirmRewatch = false
    private var entry: Entry? { store.snapshot.entries.first { $0.id == id } }
    var body: some View {
        Group {
            if let e = entry {
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        CoverView(data:e.coverData,url:e.coverURL,entryID:e.id).frame(height:330).clipShape(RoundedRectangle(cornerRadius:24))
                        Text(e.title).font(.largeTitle.bold()).fixedSize(horizontal:false,vertical:true)
                        if !e.originalTitle.isEmpty && e.originalTitle != e.title { Text(e.originalTitle).foregroundStyle(.secondary) }
                        HStack {
                            VStack(alignment:.leading,spacing:5) { Text("Последняя просмотренная").font(.subheadline).foregroundStyle(.secondary); Text("Серия \(e.episode)").font(.title.bold()).contentTransition(.numericText(value:Double(e.episode))).animation(.snappy,value:e.episode); if let season = e.season { Text("Сезон \(season)") }; if let pass = e.passTitle { Text(pass).font(.caption).foregroundStyle(.secondary) } }
                            Spacer(); IncrementButton(entry:e)
                        }
                        HStack { Label(e.status.rawValue,systemImage:"bookmark"); Spacer(); Button { var copy = e; copy.favorite.toggle(); copy.updatedAt = Date(); _ = store.save(copy) } label: { Label(e.favorite ? "В избранном" : "В избранное",systemImage:e.favorite ? "star.fill" : "star") }.frame(minHeight:44) }.font(.subheadline)
                        HStack {
                            RatingStars(rating:Binding(get:{e.rating},set:{ value in var copy = e; copy.rating = value; copy.updatedAt = Date(); _ = store.save(copy) }))
                            Spacer()
                            if let done = e.completedAt { Text("Завершено \(done.formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let available = Backlog.available(e) { Label("Доступно ещё \(available) \(episodesWord(available)) в источнике",systemImage:"play.circle").font(.subheadline.bold()).foregroundStyle(.blue) }
                        if !(e.releaseDays ?? []).isEmpty { Label("Выходит: \(ReleasePlanner.days(e))",systemImage:"calendar").font(.subheadline) }
                        if let tags = e.tags, !tags.isEmpty { TagChips(tags:tags) }
                        if let premiere = e.premiereDate, PremierePlanner.upcoming([e]).isEmpty == false { Label(PremierePlanner.label(premiere),systemImage:"sparkles").font(.subheadline.bold()).foregroundStyle(.orange) }
                        if Backlog.caughtUp(e) { Label("Догнал: жду новые серии",systemImage:"hourglass").font(.subheadline).foregroundStyle(.secondary) }
                        if let aliases = e.aliases, !aliases.isEmpty {
                            DisclosureGroup("Другие названия: \(aliases.count)") { VStack(alignment:.leading,spacing:4) { ForEach(aliases,id:\.self) { Text($0).font(.subheadline).textSelection(.enabled) } }.frame(maxWidth:.infinity,alignment:.leading) }.font(.subheadline)
                        }
                        ResumeCard(entry:e)
                        WatchLinksSection(entry:e)
                        RelatedPartsSection(entry:e)
                        NavigationLink { TitleHistoryView(id:e.id) } label: { Label("История просмотра",systemImage:"clock.arrow.circlepath") }.font(.subheadline).accessibilityIdentifier("entry-history")
                        Button("Источники новых серий",systemImage:"bell.badge") { showSources = true }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("entry-sources")
                        if let discovery = e.coverDiscovery { Text(discovery.message).font(.footnote).foregroundStyle(.secondary); if discovery.needsChoice { Button("Выбрать обложку") { editing = true } } }
                        if e.coverData != nil, e.coverDiscovery != nil { Label("Обложка сохранена для офлайн-просмотра",systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("cached-auto-cover") }
                        ForEach(e.subscriptions ?? []) { source in
                            VStack(alignment:.leading,spacing:4) { Text(source.label).font(.subheadline.bold()); if let episode = source.lastEpisode { Text("В источнике доступна серия \(episode)").font(.subheadline).foregroundStyle(.secondary) }; if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) } }
                        }
                        if !e.note.isEmpty { VStack(alignment:.leading,spacing:8) { Text("Заметка").font(.headline); Text(e.note).textSelection(.enabled) } }
                        if let url = validWebURL(e.watchURL) { Link(destination:url) { Label("Открыть страницу просмотра",systemImage:"play.rectangle").frame(maxWidth:.infinity,minHeight:48) }.buttonStyle(.borderedProminent) }
                        if let url = validWebURL(e.sourceURL) { Link("Карточка произведения: \(url.host?.contains("kitsu") == true ? "Kitsu" : "Shikimori") ↗",destination:url).font(.footnote) }
                        if e.episode > 0 || e.status == .completed { Button("Начать пересмотр",systemImage:"arrow.counterclockwise") { confirmRewatch = true }.frame(minHeight:44).accessibilityIdentifier("start-rewatch") }
                        Button("Удалить из коллекции",role:.destructive) { deleteConfirmation = true }.frame(minHeight:44)
                    }.padding(20)
                }.background(CoverAtmosphere(data:e.coverData)).tint(CoverPalette.accent(e.coverData) ?? .blue)
                    .confirmationDialog("Начать «\(e.title)» заново?",isPresented:$confirmRewatch,titleVisibility:.visible) {
                        Button("Начать пересмотр") { var copy = e; copy.startRewatch(); _ = store.save(copy) }
                    } message: { Text("Номер серии станет 0, статус — «Смотрю». Сколько серий было в прошлый раз, сохранится в карточке.") }
                    .toolbar { Button("Изменить") { editing = true }.accessibilityIdentifier("edit-entry") }
                    .sheet(isPresented:$editing) { EntryEditor(entry:e) {} }
                    .sheet(isPresented:$showSources) { EntrySourcesView(entryID:id) }
                    .confirmationDialog("Удалить «\(e.title)» и прогресс?",isPresented:$deleteConfirmation,titleVisibility:.visible) {
                        Button("Удалить запись",role:.destructive) { if store.change({ $0.entries.removeAll { $0.id == id } }) { dismiss() } }
                    } message: { Text("Вернуть запись можно из заранее сохранённой резервной копии.") }
            } else { ContentUnavailableView("Запись удалена",systemImage:"books.vertical") }
        }.navigationBarTitleDisplayMode(.inline)
    }
}
func validWebURL(_ string: String) -> URL? {
    guard let url = URL(string:string), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }; return url
}

struct EntryEditor: View {
    @State var entry: Entry
    let onSaved: () -> Void
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var network: NetworkService
    @Environment(\.dismiss) var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var selectSource = false
    @State private var alternatives: [String] = []
    @State private var loading = false
    @State private var validation: String?
    @State private var hasSeason = false
    @State private var loadingPhoto = false
    @State private var coverChanged = false
    @State private var tagsText = ""
    @State private var aliasesText = ""
    @State private var related: Set<UUID> = []
    @State private var pickingRelated = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Название и прогресс") {
                    TextField("Привычное название",text:$entry.title,axis:.vertical).accessibilityIdentifier("entry-title")
                    HStack { Text("Последняя серия"); Spacer(); TextField("0",value:$entry.episode,format:.number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth:70).accessibilityIdentifier("entry-episode") }
                    Toggle("Указывать сезон",isOn:$hasSeason).onChange(of:hasSeason) { _, value in entry.season = value ? (entry.season ?? 1) : nil }
                    if hasSeason { Stepper("Сезон \(entry.season ?? 1)",value:Binding(get:{entry.season ?? 1},set:{entry.season = $0}),in:1...10000) }
                    Picker("Статус",selection:$entry.status) { ForEach(WatchStatus.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Избранное",isOn:$entry.favorite)
                    HStack { Text("Моя оценка"); Spacer(); RatingStars(rating:$entry.rating) }
                }
                Section {
                    WeekdayPicker(days:Binding(get:{entry.releaseDays ?? []},set:{entry.releaseDays = $0.isEmpty ? nil : $0}))
                    TextField("Метки через запятую: дунхуа, с другом",text:$tagsText,axis:.vertical).accessibilityIdentifier("entry-tags")
                    Toggle("Дата премьеры",isOn:Binding(get:{entry.premiereDate != nil},set:{ entry.premiereDate = $0 ? (entry.premiereDate ?? Calendar.current.startOfDay(for:Date().addingTimeInterval(86400))) : nil }))
                    if let premiere = entry.premiereDate { DatePicker("Премьера",selection:Binding(get:{premiere},set:{entry.premiereDate = $0}),displayedComponents:.date) }
                    Button { pickingRelated = true } label: { HStack { Text("Связанные части"); Spacer(); Text(related.isEmpty ? "нет" : "\(related.count)").foregroundStyle(.secondary) } }.accessibilityIdentifier("pick-related")
                } header: { Text("Дни выхода и метки") } footer: { Text("Дни выхода указываете вы сами: приложение их не угадывает. В эти дни сводка напомнит о новых сериях, если её включить в Настройках. В день премьеры в 10:00 придёт одно напоминание.") }
                Section("Обложка") {
                    HStack { Spacer(); CoverView(data:entry.coverData,url:entry.coverURL).frame(width:140,height:185).clipShape(RoundedRectangle(cornerRadius:16)); Spacer() }
                    Button("Найти произведение / сменить обложку",systemImage:"magnifyingglass") { selectSource = true }
                    PhotosPicker(selection:$photo,matching:.images,photoLibrary:.shared()) { Label("Своя обложка из Фото",systemImage:"photo") }
                    if loadingPhoto { ProgressView("Подготовка изображения…") }
                    if let source = entry.sourceID {
                        Button("Другие изображения этого произведения") { Task { loading = true; defer { loading = false }; do { alternatives = try await network.alternatives(id:source); if alternatives.isEmpty { validation = "Для этого произведения других изображений нет." } } catch { validation = error.localizedDescription } } }.disabled(loading)
                    }
                    if loading { ProgressView() }
                    if !alternatives.isEmpty {
                        ScrollView(.horizontal) { HStack { ForEach(alternatives,id:\.self) { url in Button { entry.coverURL = url; entry.coverData = nil; entry.coverDiscovery = nil; entry.coverLookupDisabled = false; coverChanged = true; alternatives = [] } label: { CoverView(data:nil,url:url).frame(width:120,height:90).clipShape(RoundedRectangle(cornerRadius:10)) }.accessibilityLabel("Выбрать изображение произведения") } } }
                    }
                    if !entry.coverURL.isEmpty || entry.coverData != nil { Button("Убрать обложку",role:.destructive) { entry.coverURL = ""; entry.coverData = nil; entry.coverDiscovery = nil; entry.coverLookupDisabled = true; coverChanged = true } }
                    Toggle("Искать обложку автоматически",isOn:Binding(get:{entry.coverLookupDisabled != true},set:{entry.coverLookupDisabled = !$0; if $0 { entry.coverDiscovery = nil } }))
                }
                Section {
                    TextField("Каждое название с новой строки",text:$aliasesText,axis:.vertical).lineLimit(2...8).accessibilityIdentifier("entry-aliases")
                } header: { Text("Другие названия") } footer: { Text("Английские, оригинальные и ваши варианты. По ним работают поиск в коллекции, проверка дублей при импорте и подбор страницы AniVibe. Названия из каталога и источника добавляются сами; ваше главное название не меняется.") }
                Section("Заметка и ссылка") {
                    TextField("Заметка",text:$entry.note,axis:.vertical).lineLimit(3...8)
                    TextField("https://… — страница просмотра",text:$entry.watchURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if !entry.originalTitle.isEmpty { Section("Из каталога") { Text(entry.originalTitle).foregroundStyle(.secondary); Text("Сезон и прогресс не определяются автоматически. Можно вести сквозную нумерацию.").font(.caption) } }
            }
            .navigationTitle(store.snapshot.entries.contains { $0.id == entry.id } ? "Редактирование" : "Новая история").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Сохранить") { save() }.disabled(loadingPhoto).accessibilityIdentifier("save-entry") }
            }
            .sheet(isPresented:$selectSource) { NavigationStack { SearchView(selectingCover:true,initialQuery:entry.title) { candidate in
                if let c = candidate { entry.originalTitle = c.name; entry.sourceID = c.shikimoriID; entry.sourceURL = c.pageURL; entry.coverURL = c.posterURL; entry.coverData = nil; entry.coverLookupDisabled = false; entry.coverDiscovery = nil; if entry.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { entry.title = c.title }; aliasesText = Aliases.merge(Aliases.parse(aliasesText),adding:c.names,except:[entry.title]).joined(separator:"\n") }
                coverChanged = true; alternatives = []; selectSource = false
            } } }
            .sheet(isPresented:$pickingRelated) { RelatedPicker(entryID:entry.id,selected:$related) }
            .onAppear { related = Set(Relations.related(of:entry,in:store.snapshot.entries).map(\.id)); hasSeason = entry.season != nil; tagsText = (entry.tags ?? []).joined(separator:", "); aliasesText = (entry.aliases ?? []).joined(separator:"\n") }
            .onChange(of:photo) { _, value in Task {
                guard let value else { return }; loadingPhoto = true; defer { loadingPhoto = false }
                do { guard let data = try await value.loadTransferable(type:Data.self), let normalized = NetworkService.normalized(data) else { throw ShelfError.invalid("Не удалось открыть изображение. Выберите файл до 20 МБ.") }; entry.coverData = normalized; entry.coverURL = ""; entry.coverDiscovery = nil; coverChanged = true }
                catch { validation = error.localizedDescription }
            } }
            .alert("Проверьте данные",isPresented:Binding(get:{validation != nil},set:{if !$0 {validation = nil}})) { Button("Понятно",role:.cancel) {} } message: { Text(validation ?? "") }
        }
    }
    private func save() {
        entry.title = entry.title.trimmingCharacters(in:.whitespacesAndNewlines)
        entry.watchURL = entry.watchURL.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !entry.title.isEmpty else { validation = "Введите название."; return }
        guard entry.watchURL.isEmpty || validWebURL(entry.watchURL) != nil else { validation = "Ссылка должна начинаться с http:// или https:// и содержать адрес сайта."; return }
        let tags = Tags.parse(tagsText); entry.tags = tags.isEmpty ? nil : tags
        let aliases = Aliases.merge(nil,adding:Aliases.parse(aliasesText),except:[entry.title]); entry.aliases = aliases.isEmpty ? nil : aliases
        let old = store.snapshot.entries.first { $0.id == entry.id }
        if old?.episode != entry.episode { entry.watchedAt = Date() }
        entry.updatedAt = Date()
        if let old {
            // Фоновые обложки и проверки источников могли завершиться, пока открыт редактор.
            entry.subscriptions = old.subscriptions; entry.releaseNotices = old.releaseNotices
            if !coverChanged, entry.coverLookupDisabled != true, entry.coverURL.isEmpty, entry.coverData == nil, !old.coverURL.isEmpty {
                entry.coverURL = old.coverURL; entry.coverData = old.coverData; entry.sourceID = old.sourceID
                entry.sourceURL = old.sourceURL; entry.originalTitle = old.originalTitle; entry.coverDiscovery = old.coverDiscovery
            }
            if entry.coverData == nil, !entry.coverURL.isEmpty, entry.coverURL == old.coverURL { entry.coverData = old.coverData }
        }
        // Links work both ways, so a removed link is also removed from the other title.
        let before = Set(Relations.related(of:old ?? entry,in:store.snapshot.entries).map(\.id))
        let removed = before.subtracting(related)
        entry.relatedIDs = related.isEmpty ? nil : Array(related.prefix(Relations.limit))
        let toSave = entry
        if store.change({ state in state.save(toSave); for other in removed { Relations.unlink(toSave.id,other,in:&state) } }) {
            if entry.premiereDate != nil { Task { _ = await NotificationBridge.shared.enable() } }
            dismiss(); onSaved()
        }
        else { validation = store.error; store.error = nil }
    }
}
