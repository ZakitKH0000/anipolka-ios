import SwiftUI

enum WizardStep: Int, CaseIterable {
    case find, progress, source, finish
    var title: String {
        switch self {
        case .find: return "Найти"
        case .progress: return "Прогресс"
        case .source: return "Где смотрю"
        case .finish: return "Готово"
        }
    }
}

/// Search state lives outside the step view, so going back keeps the results.
@MainActor final class WizardSearch: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "Везде", shikimori = "Shikimori", kitsu = "Kitsu"
        var id: String { rawValue }
    }
    @Published var query = ""
    @Published var scope: Scope = .all
    @Published private(set) var results: [AnimeCandidate] = []
    @Published private(set) var loading = false
    @Published private(set) var searched = false
    @Published private(set) var message: String?
    private var task: Task<Void,Never>?

    func reset() { task?.cancel(); loading = false; searched = false; results = []; message = nil }
    func cancel() { task?.cancel(); loading = false }

    func run(network: NetworkService) {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        task?.cancel(); loading = true; searched = true; message = nil; results = []
        let scope = self.scope
        task = Task {
            var merged: [AnimeCandidate] = []
            var failed: [String] = []
            if scope != .kitsu {
                do { merged += try await network.search(term,catalog:.shikimori) }
                catch is CancellationError { return }
                catch { if Task.isCancelled { return }; failed.append("Shikimori") }
            }
            if scope != .shikimori {
                do {
                    let found = try await network.search(term,catalog:.kitsu)
                    // The same edition from both catalogues is listed once, Shikimori first.
                    let extra = found.filter { candidate in !merged.contains { $0.sameEdition(as:candidate) } }
                    merged += extra
                }
                catch is CancellationError { return }
                catch { if Task.isCancelled { return }; failed.append("Kitsu") }
            }
            guard !Task.isCancelled else { return }
            results = merged; loading = false
            if merged.isEmpty, !failed.isEmpty { message = "Не удалось выполнить поиск: \(failed.joined(separator:", ")) сейчас недоступен." }
        }
    }
}

struct AddWizardView: View {
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = WizardSearch()
    @State private var step: WizardStep = .find
    @State private var draft = Entry(title:"")
    @State private var picked: AnimeCandidate?
    @State private var confirmClose = false
    @State private var confirmDuplicate = false
    @State private var problem: String?

    private var started: Bool { step != .find || !search.query.isEmpty }
    private var trimmedTitle: String { draft.title.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var hasSource: Bool { !(draft.subscriptions ?? []).isEmpty || !draft.watchURL.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    /// An entry already known under this or another of its names.
    private var duplicate: Entry? {
        ([draft.title,draft.originalTitle] + (draft.aliases ?? [])).lazy.compactMap { TitleMatcher.existing($0,in:store.snapshot.entries) }.first
    }

    var body: some View {
        VStack(spacing:0) {
            header
            ZStack {
                switch step {
                case .find: WizardFindStep(search:search,existing:store.snapshot.entries,onPick:pick,onManual:manual)
                case .progress: WizardProgressStep(draft:$draft)
                case .source: WizardSourceStep(draft:$draft)
                case .finish: WizardFinishStep(draft:$draft,picked:picked)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).animation(.snappy,value:step)
            if step != .find { footer }
        }
        .background(ShelfDesign.background.ignoresSafeArea())
        .interactiveDismissDisabled(started)
        .onDisappear { search.cancel() }
        .confirmationDialog("Закрыть без сохранения?",isPresented:$confirmClose,titleVisibility:.visible) {
            Button("Закрыть",role:.destructive) { dismiss() }
            Button("Продолжить добавление",role:.cancel) {}
        } message: { Text("Введённые данные не сохранятся.") }
        .confirmationDialog("Такая история уже есть: «\(duplicate?.title ?? "")»",isPresented:$confirmDuplicate,titleVisibility:.visible) {
            Button("Всё равно добавить") { save() }
            Button("Назад",role:.cancel) {}
        } message: { Text("Совпало одно из названий. Если это другой сезон или фильм, добавьте ещё одну запись.") }
        .alert("Не удалось добавить",isPresented:Binding(get:{problem != nil},set:{if !$0 { problem = nil }})) { Button("Понятно",role:.cancel) {} } message: { Text(problem ?? "") }
    }

    private var header: some View {
        VStack(spacing:12) {
            HStack {
                Button { if started { confirmClose = true } else { dismiss() } } label: { Image(systemName:"xmark").font(.headline).frame(width:44,height:44) }
                    .accessibilityLabel("Закрыть").accessibilityIdentifier("wizard-close")
                Spacer()
                Text("Шаг \(step.rawValue + 1) из \(WizardStep.allCases.count) · \(step.title)").font(.subheadline.weight(.semibold)).accessibilityIdentifier("wizard-step-title")
                Spacer()
                Color.clear.frame(width:44,height:44)
            }.padding(.horizontal,12)
            HStack(spacing:6) {
                ForEach(WizardStep.allCases,id:\.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Color.blue : Color.secondary.opacity(0.25)).frame(height:4)
                }
            }.padding(.horizontal,20).accessibilityHidden(true)
        }.padding(.top,8).padding(.bottom,4)
    }

    private var footer: some View {
        HStack(spacing:12) {
            Button { back() } label: { Label("Назад",systemImage:"chevron.left").frame(minHeight:44) }.buttonStyle(.bordered).accessibilityIdentifier("wizard-back")
            primaryButton
        }.padding(.horizontal,20).padding(.vertical,12).background(.bar)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .find:
            EmptyView()
        case .progress:
            Button { go(.source) } label: { Text("Далее").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(trimmedTitle.isEmpty).accessibilityIdentifier("wizard-next")
        case .source:
            Button { go(.finish) } label: { Text(hasSource ? "Далее" : "Пропустить").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("wizard-next")
        case .finish:
            Button { finishTapped() } label: { Label("Добавить в коллекцию",systemImage:"checkmark").frame(maxWidth:.infinity,minHeight:44) }
                .buttonStyle(.borderedProminent).disabled(trimmedTitle.isEmpty).accessibilityIdentifier("wizard-finish")
        }
    }

    private func go(_ next: WizardStep) { withAnimation(.snappy) { step = next } }
    private func back() { if let previous = WizardStep(rawValue:step.rawValue - 1) { go(previous) } }

    private func pick(_ candidate: AnimeCandidate) {
        var entry = Entry(title:candidate.title)
        entry.originalTitle = candidate.name; entry.sourceID = candidate.shikimoriID; entry.sourceURL = candidate.pageURL
        entry.coverURL = candidate.posterURL; entry.coverLookupDisabled = false
        entry.learnNames(candidate.names)
        draft = entry; picked = candidate; go(.progress)
    }
    private func manual(_ text: String) {
        draft = Entry(title:text.trimmingCharacters(in:.whitespacesAndNewlines)); picked = nil; go(.progress)
    }
    private func finishTapped() {
        if duplicate != nil { confirmDuplicate = true } else { save() }
    }
    private func save() {
        var entry = draft
        entry.title = trimmedTitle
        entry.watchURL = entry.watchURL.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !entry.title.isEmpty else { problem = "Введите название."; go(.progress); return }
        guard entry.watchURL.isEmpty || validWebURL(entry.watchURL) != nil else {
            problem = "Ссылка для просмотра должна начинаться с http:// или https:// и содержать адрес сайта."; go(.source); return
        }
        let now = Date()
        entry.updatedAt = now
        if entry.episode > 0 { entry.watchedAt = now }
        if store.save(entry) {
            // The premiere reminder needs notification permission.
            if entry.premiereDate != nil { Task { _ = await NotificationBridge.shared.enable() } }
            dismiss()
        } else { problem = store.error ?? "Не удалось сохранить."; store.error = nil }
    }
}

private struct WizardBlock<Content: View>: View {
    let title: String
    let caption: String?
    let content: Content
    init(title: String,caption: String? = nil,@ViewBuilder content: () -> Content) {
        self.title = title; self.caption = caption; self.content = content()
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(title).font(.headline)
            content
            if let caption { Text(caption).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Step 1 — find

private struct WizardFindStep: View {
    @ObservedObject var search: WizardSearch
    let existing: [Entry]
    let onPick: (AnimeCandidate) -> Void
    let onManual: (String) -> Void
    @EnvironmentObject var network: NetworkService
    private var trimmed: String { search.query.trimmingCharacters(in:.whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Что добавляем?").font(.largeTitle.bold())
                Text("Введите название на русском, английском или оригинале. Ищем в Shikimori и Kitsu — выберите нужный сезон из списка.").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing:10) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Например: Tunshi Xingkong",text:$search.query).submitLabel(.search).autocorrectionDisabled()
                        .onSubmit { search.run(network:network) }.accessibilityIdentifier("catalog-query")
                    if search.loading { ProgressView() }
                    else if !search.query.isEmpty {
                        Button { search.query = ""; search.reset() } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary).frame(width:32,height:32) }.accessibilityLabel("Очистить")
                    }
                }.padding(14).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:16,style:.continuous))
                Picker("Где искать",selection:$search.scope) { ForEach(WizardSearch.Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("catalog-provider")
                Button { search.run(network:network) } label: { Text("Искать").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.borderedProminent).disabled(trimmed.isEmpty || search.loading).accessibilityIdentifier("catalog-search")
                if !network.canLoadCovers && network.wifiOnly {
                    Label("Обложки загрузятся при подключении к Wi-Fi. Поиск названий доступен через любую сеть.",systemImage:"wifi").font(.footnote).foregroundStyle(.secondary)
                }
                if let message = search.message { Text(message).foregroundStyle(.secondary) }
                if search.searched && !search.loading && search.results.isEmpty && search.message == nil {
                    Text("Совпадений нет. Попробуйте короткое или оригинальное название, другой каталог или добавьте вручную.").foregroundStyle(.secondary)
                }
                // Both catalogues number their entries separately, so rows are keyed by position.
                ForEach(Array(search.results.enumerated()),id:\.offset) { index,candidate in resultRow(candidate,index:index) }
                Divider().padding(.vertical,4)
                Button { onManual(search.query) } label: { Label("Добавить вручную",systemImage:"square.and.pencil").frame(maxWidth:.infinity,minHeight:44) }
                    .buttonStyle(.bordered).accessibilityIdentifier("manual-add")
                Text("Вручную можно ввести привычное название и сквозной номер серии. Обложка подберётся сама или её можно выбрать позже. Каталоги содержат не все дунхуа и варианты перевода.").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
    }

    private func resultRow(_ candidate: AnimeCandidate,index: Int) -> some View {
        let known = candidate.names.lazy.compactMap { TitleMatcher.existing($0,in:existing) }.first
        let catalog = candidate.catalog == .kitsu ? "Kitsu" : "Shikimori"
        return Button { onPick(candidate) } label: {
            HStack(alignment:.top,spacing:14) {
                CoverView(data:nil,url:candidate.previewURL).frame(width:68,height:96).clipShape(RoundedRectangle(cornerRadius:12,style:.continuous))
                VStack(alignment:.leading,spacing:6) {
                    Text(candidate.title).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Text(candidate.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    HStack(spacing:6) {
                        Text(catalog).font(.caption2.bold()).padding(.horizontal,8).padding(.vertical,3).background(Color.secondary.opacity(0.15),in:Capsule())
                        if let known { Label("Уже есть: \(known.title)",systemImage:"checkmark.circle").font(.caption2).foregroundStyle(.orange).lineLimit(1) }
                    }
                }
                Spacer(minLength:0)
                Image(systemName:"chevron.right").font(.footnote).foregroundStyle(.tertiary).padding(.top,4)
            }.padding(12).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:18,style:.continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityValue("\(candidate.detail). \(catalog)" + (known.map { ". Уже есть в коллекции: \($0.title)" } ?? ""))
        .accessibilityIdentifier("wizard-result-\(index)")
    }
}

// MARK: Step 2 — progress

private struct WizardProgressStep: View {
    @Binding var draft: Entry
    @State private var hasSeason = false
    private let icons: [WatchStatus:String] = [.watching:"play.fill",.planned:"clock",.completed:"checkmark.circle",.dropped:"xmark.circle"]

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.top,spacing:14) {
                    CoverView(data:draft.coverData,url:draft.coverURL).frame(width:84,height:118).clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
                    VStack(alignment:.leading,spacing:6) {
                        Text("Ваше название").font(.caption).foregroundStyle(.secondary)
                        TextField("Привычное название",text:$draft.title,axis:.vertical).font(.title3.bold()).accessibilityIdentifier("entry-title")
                        if !draft.originalTitle.isEmpty && draft.originalTitle != draft.title { Text(draft.originalTitle).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                WizardBlock(title:"Статус") {
                    LazyVGrid(columns:[GridItem(.flexible(),spacing:10),GridItem(.flexible(),spacing:10)],spacing:10) {
                        ForEach(WatchStatus.allCases) { status in
                            let selected = draft.status == status
                            Button { draft.status = status } label: {
                                Label(status.rawValue,systemImage:icons[status] ?? "circle").font(.subheadline.weight(selected ? .semibold : .regular)).frame(maxWidth:.infinity,minHeight:48)
                                    .background(selected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:14,style:.continuous))
                                    .foregroundStyle(selected ? Color.blue : Color.primary)
                                    .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(selected ? Color.blue.opacity(0.6) : .clear))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
                WizardBlock(title:"На какой серии вы остановились?",caption:"0 — ещё не начинали. Номер можно вести сквозной, как вам удобно: приложение его не меняет само.") {
                    HStack(spacing:12) {
                        Button { draft.episode = max(0,draft.episode - 1) } label: { Image(systemName:"minus").frame(width:44,height:44) }.buttonStyle(.bordered).accessibilityLabel("Уменьшить номер серии")
                        TextField("0",value:$draft.episode,format:.number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.center)
                            .font(.title.bold()).frame(maxWidth:.infinity).accessibilityIdentifier("entry-episode")
                        Button { draft.episode = min(1_000_000,draft.episode + 1) } label: { Image(systemName:"plus").frame(width:44,height:44) }.buttonStyle(.bordered).accessibilityLabel("Увеличить номер серии")
                    }
                }
                WizardBlock(title:"Сезон",caption:"Необязательно. Сезон не определяется автоматически.") {
                    Toggle("Указать сезон",isOn:$hasSeason).onChange(of:hasSeason) { _, value in draft.season = value ? (draft.season ?? 1) : nil }
                    if hasSeason { Stepper("Сезон \(draft.season ?? 1)",value:Binding(get:{draft.season ?? 1},set:{draft.season = $0}),in:1...10000) }
                }
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { hasSeason = draft.season != nil }
    }
}

// MARK: Step 3 — where to watch

private struct WizardSourceStep: View {
    @Binding var draft: Entry
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @State private var suggestions: [AnivibeCatalog.Page]?
    @State private var searching = false
    @State private var address = ""
    @State private var page: SourcePage?
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("Где вы смотрите?").font(.largeTitle.bold())
                Text("Подключите озвучку на AniVibe, чтобы видеть «+N серий» и получать уведомления о новых. Шаг можно пропустить и вернуться к нему позже в карточке.").font(.subheadline).foregroundStyle(.secondary)
                connected
                Button { findPages() } label: {
                    HStack(spacing:8) { Label("Найти на AniVibe по названиям",systemImage:"text.magnifyingglass"); if searching { ProgressView() } }.frame(maxWidth:.infinity,minHeight:44)
                }.buttonStyle(.borderedProminent).disabled(searching || draft.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("find-anivibe")
                if let suggestions {
                    if suggestions.isEmpty {
                        Text("Страница не найдена ни по одному названию. Вставьте ссылку ниже или вернитесь и добавьте английское название.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(suggestions) { item in
                        Button { address = item.url; self.suggestions = nil; load() } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(item.slugName.capitalized).foregroundStyle(.primary)
                                Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous))
                        }.buttonStyle(.plain)
                    }
                }
                WizardBlock(title:"Или вставьте ссылку на страницу AniVibe") {
                    TextField("https://anivibe.pro/anime/…",text:$address,axis:.vertical).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous)).accessibilityIdentifier("source-url")
                    Button("Проверить страницу") { load() }.buttonStyle(.bordered).disabled(loading || address.isEmpty).accessibilityIdentifier("inspect-source")
                }
                if loading { ProgressView("Читаю доступные серии…") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if let page { options(for:page) }
                WizardBlock(title:"Ссылка для просмотра",caption:"Необязательно. Кнопка «Открыть страницу просмотра» откроет её. Остальные площадки и плейлисты можно добавить позже с подписями.") {
                    TextField("https://…",text:$draft.watchURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous)).accessibilityIdentifier("wizard-watch-url")
                }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var connected: some View {
        if let sources = draft.subscriptions, !sources.isEmpty {
            WizardBlock(title:"Подключено") {
                ForEach(sources) { source in
                    HStack {
                        VStack(alignment:.leading,spacing:2) {
                            Text(source.label).font(.subheadline.weight(.semibold))
                            if let episode = source.lastEpisode { Text("Сейчас доступна серия \(episode)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { draft.subscriptions?.removeAll { $0.id == source.id }; if draft.subscriptions?.isEmpty == true { draft.subscriptions = nil } } label: { Image(systemName:"minus.circle").frame(width:44,height:44) }
                            .accessibilityLabel("Убрать источник \(source.label)")
                    }.padding(.horizontal,12).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous))
                }
            }
        }
    }

    private func options(for page: SourcePage) -> some View {
        VStack(alignment:.leading,spacing:10) {
            Text(page.title).font(.headline)
            if !TitleMatcher.matches(page.names + [page.title],draft) {
                Label("Названия страницы не совпали ни с одним названием этой истории. Проверьте, что это то же произведение и нужный сезон.",systemImage:"exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Text("Выберите озвучку и сезон. Звёздочка добавляет озвучку в любимые: такие идут первыми.").font(.footnote).foregroundStyle(.secondary)
            ForEach(Dubs.sorted(page.options,favorites:store.snapshot.preferences.favoriteDubs)) { option in
                HStack(spacing:4) {
                    favoriteButton(option.label)
                    Button {
                        if draft.attachSource(page:page,option:option) {
                            self.page = nil; message = "Подключено: \(option.label). Сейчас доступна серия \(option.episode)."
                        }
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text(option.label).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Text("Доступно серий: \(option.episode) · Подключить").font(.subheadline).foregroundStyle(.blue)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,10)
                    }
                    .disabled((draft.subscriptions ?? []).contains { $0.pageURL == page.url && $0.optionID == option.id })
                    .accessibilityIdentifier("source-option-\(option.id)")
                }.padding(.horizontal,8).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous))
            }
        }
    }

    private func favoriteButton(_ label: String) -> some View {
        let name = Dubs.name(fromLabel:label)
        let favorite = Dubs.isFavorite(name,in:store.snapshot.preferences.favoriteDubs)
        return Button { _ = store.change { $0.preferences.favoriteDubs = Dubs.toggled(name,in:$0.preferences.favoriteDubs) } } label: {
            Image(systemName:favorite ? "star.fill" : "star").foregroundStyle(.yellow).frame(width:40,height:44)
        }.accessibilityLabel(favorite ? "Убрать «\(name)» из любимых озвучек" : "Добавить «\(name)» в любимые озвучки")
    }

    private func findPages() {
        searching = true; suggestions = nil; message = nil
        let entry = draft
        Task {
            defer { searching = false }
            do { suggestions = try await assistant.anivibeCandidates(for:entry) }
            catch { message = error.localizedDescription }
        }
    }
    private func load() {
        loading = true; message = nil; page = nil
        let target = address
        Task {
            defer { loading = false }
            do { page = try await assistant.readPage(target) }
            catch { message = error.localizedDescription }
        }
    }
}

// MARK: Step 4 — finish

private struct WizardFinishStep: View {
    @Binding var draft: Entry
    let picked: AnimeCandidate?
    @State private var tagsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("Почти готово").font(.largeTitle.bold())
                summary
                WizardBlock(title:"Дни выхода",caption:"Отметьте дни недели, когда обычно выходит серия: в эти дни придёт одна сводка, если она включена в Настройках. Приложение дни не угадывает.") {
                    WeekdayPicker(days:Binding(get:{draft.releaseDays ?? []},set:{draft.releaseDays = $0.isEmpty ? nil : $0}))
                }
                WizardBlock(title:"Премьера",caption:"В день премьеры в 10:00 придёт одно напоминание.") {
                    Toggle("Дата премьеры",isOn:Binding(get:{draft.premiereDate != nil},set:{ draft.premiereDate = $0 ? (draft.premiereDate ?? Calendar.current.startOfDay(for:Date().addingTimeInterval(86400))) : nil }))
                    if let premiere = draft.premiereDate { DatePicker("Премьера",selection:Binding(get:{premiere},set:{draft.premiereDate = $0}),displayedComponents:.date) }
                }
                WizardBlock(title:"Оценка") { RatingStars(rating:$draft.rating) }
                WizardBlock(title:"Метки и заметка") {
                    TextField("Метки через запятую: дунхуа, с другом",text:$tagsText,axis:.vertical).padding(14)
                        .background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous)).accessibilityIdentifier("entry-tags")
                    TextField("Заметка",text:$draft.note,axis:.vertical).lineLimit(2...6).padding(14)
                        .background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:14,style:.continuous))
                }
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { tagsText = (draft.tags ?? []).joined(separator:", ") }
        .onChange(of:tagsText) { _, text in let tags = Tags.parse(text); draft.tags = tags.isEmpty ? nil : tags }
    }

    private var summary: some View {
        HStack(alignment:.top,spacing:14) {
            CoverView(data:draft.coverData,url:draft.coverURL).frame(width:84,height:118).clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
            VStack(alignment:.leading,spacing:6) {
                Text(draft.title).font(.title3.bold()).fixedSize(horizontal:false,vertical:true)
                Text("\(draft.status.rawValue) · серия \(draft.episode)" + (draft.season.map { " · сезон \($0)" } ?? "")).font(.subheadline).foregroundStyle(.secondary)
                if let count = draft.subscriptions?.count, count > 0 { Label("Источников серий: \(count)",systemImage:"bell.badge").font(.footnote).foregroundStyle(.blue) }
                else if !draft.watchURL.isEmpty { Label("Есть ссылка для просмотра",systemImage:"play.rectangle").font(.footnote).foregroundStyle(.blue) }
                Label(picked != nil && !draft.coverURL.isEmpty ? "Обложка из каталога" : "Обложка подберётся автоматически",systemImage:"photo").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }.padding(14).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:20,style:.continuous))
    }
}
