import SwiftUI
import PhotosUI

struct EntryDetail: View {
    let id: UUID
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var editing = false
    @State private var deleteConfirmation = false
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
                            VStack(alignment:.leading,spacing:5) { Text("Последняя просмотренная").font(.subheadline).foregroundStyle(.secondary); Text("Серия \(e.episode)").font(.title.bold()); if let season = e.season { Text("Сезон \(season)") } }
                            Spacer(); IncrementButton(entry:e)
                        }
                        HStack { Label(e.status.rawValue,systemImage:"bookmark"); Spacer(); Button { var copy = e; copy.favorite.toggle(); copy.updatedAt = Date(); _ = store.save(copy) } label: { Label(e.favorite ? "В избранном" : "В избранное",systemImage:e.favorite ? "star.fill" : "star") }.frame(minHeight:44) }.font(.subheadline)
                        if !e.note.isEmpty { VStack(alignment:.leading,spacing:8) { Text("Заметка").font(.headline); Text(e.note).textSelection(.enabled) } }
                        if let url = validWebURL(e.watchURL) { Link(destination:url) { Label("Открыть страницу просмотра",systemImage:"play.rectangle").frame(maxWidth:.infinity,minHeight:48) }.buttonStyle(.borderedProminent) }
                        if let url = validWebURL(e.sourceURL) { Link("Карточка произведения: Shikimori ↗",destination:url).font(.footnote) }
                        Button("Удалить из коллекции",role:.destructive) { deleteConfirmation = true }.frame(minHeight:44)
                    }.padding(20)
                }.background(ShelfDesign.background)
                    .toolbar { Button("Изменить") { editing = true }.accessibilityIdentifier("edit-entry") }
                    .sheet(isPresented:$editing) { EntryEditor(entry:e) {} }
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
                }
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
                        ScrollView(.horizontal) { HStack { ForEach(alternatives,id:\.self) { url in Button { entry.coverURL = url; entry.coverData = nil; alternatives = [] } label: { CoverView(data:nil,url:url).frame(width:120,height:90).clipShape(RoundedRectangle(cornerRadius:10)) }.accessibilityLabel("Выбрать изображение произведения") } } }
                    }
                    if !entry.coverURL.isEmpty || entry.coverData != nil { Button("Убрать обложку",role:.destructive) { entry.coverURL = ""; entry.coverData = nil } }
                }
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
                if let c = candidate { entry.originalTitle = c.name; entry.sourceID = c.id; entry.sourceURL = c.pageURL; entry.coverURL = c.posterURL; entry.coverData = nil; if entry.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { entry.title = c.title } }
                alternatives = []; selectSource = false
            } } }
            .onAppear { hasSeason = entry.season != nil }
            .onChange(of:photo) { _, value in Task {
                guard let value else { return }; loadingPhoto = true; defer { loadingPhoto = false }
                do { guard let data = try await value.loadTransferable(type:Data.self), let normalized = NetworkService.normalized(data) else { throw ShelfError.invalid("Не удалось открыть изображение. Выберите файл до 20 МБ.") }; entry.coverData = normalized; entry.coverURL = "" }
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
        let old = store.snapshot.entries.first { $0.id == entry.id }
        if old?.episode != entry.episode { entry.watchedAt = Date() }
        entry.updatedAt = Date()
        if store.save(entry) { dismiss(); onSaved() }
        else { validation = store.error; store.error = nil }
    }
}
