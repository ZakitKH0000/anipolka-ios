import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        TabView {
            ShelfView(favorites: false).tabItem { Label("Коллекция",systemImage:"square.stack.fill") }
            ShelfView(favorites: true).tabItem { Label("Избранное",systemImage:"star.fill") }
            NavigationStack { SearchView { _ in } }.tabItem { Label("Поиск",systemImage:"magnifyingglass") }
            NavigationStack { ReleasesView() }.tabItem { Label("Серии",systemImage:"bell") }.badge(store.snapshot.entries.flatMap { $0.releaseNotices ?? [] }.filter { !$0.read }.count)
            NavigationStack { SettingsView() }.tabItem { Label("Настройки",systemImage:"slider.horizontal.3") }
        }
        .tint(.blue)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let token = store.undoToken {
                HStack(spacing:12) {
                    Text("Серия \(token.applied.episode) отмечена").font(.subheadline).lineLimit(2)
                    Spacer(minLength:4)
                    Button("Отменить") { store.undo() }.font(.subheadline.bold()).frame(minHeight:44).accessibilityIdentifier("undo")
                }.padding(.horizontal,18).shelfGlass(in:RoundedRectangle(cornerRadius:22)).padding(.horizontal).padding(.bottom,6)
            }
        }
        .alert("Не удалось выполнить действие",isPresented: Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("Понятно",role:.cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

struct ShelfView: View {
    let favorites: Bool
    @EnvironmentObject var store: ShelfStore
    @State private var query = ""
    @State private var status: WatchStatus? = nil
    @State private var showAdd = false
    @State private var showReorder = false
    @State private var showImport = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var entries: [Entry] { store.snapshot.visible(query:query,status:status,favorites:favorites) }
    private var continuing: Entry? { entries.first { $0.status == .watching } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text(favorites ? "Истории, к которым хочется вернуться" : "Аниме и дунхуа — в своём ритме").font(.subheadline).foregroundStyle(.secondary).padding(.top,4)
                    filters
                    if let failure = store.loadFailure { Label(failure,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).padding().background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:18)) }
                    if !favorites, store.snapshot.preferences.showContinue, let entry = continuing {
                        VStack(alignment:.leading,spacing:12) {
                            Text("Продолжить просмотр").font(.title3.bold())
                            HeroCard(entry:entry)
                        }
                    }
                    HStack {
                        Text(favorites ? "Мои любимые" : "Мой список").font(.title2.bold())
                        Text("\(entries.count)").font(.title3).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Picker("Сортировка",selection:store.preference(\.sort)) { ForEach(ShelfSort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                            Picker("Вид коллекции",selection:store.preference(\.layout)) { ForEach(Layout.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                            Button("Изменить порядок",systemImage:"line.3.horizontal") { showReorder = true }
                            Button("Импорт текстового списка",systemImage:"text.badge.plus") { showImport = true }
                        } label: { Image(systemName:"slider.horizontal.3").frame(width:44,height:44) }.accessibilityLabel("Вид и сортировка")
                    }
                    if entries.isEmpty { emptyState }
                    else if store.snapshot.preferences.layout == .grid && !typeSize.isAccessibilitySize {
                        LazyVGrid(columns:[GridItem(.flexible(),spacing:14),GridItem(.flexible(),spacing:14)],alignment:.leading,spacing:24) {
                            ForEach(entries) { entry in GridCard(entry:entry) }
                        }
                    } else {
                        LazyVStack(spacing:0) {
                            ForEach(entries) { entry in
                                ShelfRow(entry:entry)
                                Divider().padding(.leading,90).padding(.vertical,12)
                            }
                        }
                    }
                    if store.demo { Text("Предпросмотр · тестовые названия и иллюстрации").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal,20).padding(.bottom,24)
            }
            .background(ShelfDesign.background)
            .navigationTitle(favorites ? "Избранное" : "Коллекция")
            .searchable(text:$query,placement:.navigationBarDrawer(displayMode:.automatic),prompt:"Найти в коллекции")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) { Button { showAdd = true } label: { Image(systemName:"plus").font(.title3) }.accessibilityLabel("Добавить произведение").accessibilityIdentifier("add") }
            }
            .sheet(isPresented:$showAdd) { NavigationStack { SearchView { _ in showAdd = false } }.environmentObject(store) }
            .sheet(isPresented:$showReorder) { ReorderView() }
            .sheet(isPresented:$showImport) { TextImportView() }
        }
    }
    private var filters: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:8) {
                filterButton("Все",value:nil)
                ForEach(WatchStatus.allCases) { filterButton($0.rawValue,value:$0) }
            }.padding(.vertical,4)
        }
    }
    private func filterButton(_ title: String,value: WatchStatus?) -> some View {
        Button { status = value } label: {
            Text(title).font(.subheadline.weight(status == value ? .semibold : .regular)).padding(.horizontal,15).frame(minHeight:44)
                .background(status == value ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.07),in:Capsule())
                .foregroundStyle(status == value ? Color.blue : Color.primary)
                .overlay(Capsule().stroke(status == value ? Color.blue.opacity(0.5) : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(status == value ? [.isSelected] : [])
    }
    private var emptyState: some View {
        VStack(spacing:16) {
            Image(systemName:favorites ? "star" : "books.vertical").font(.system(size:48,weight:.light)).foregroundStyle(.blue)
            Text(query.isEmpty && status == nil ? (favorites ? "Здесь будут любимые истории" : "Ваша полка ждёт первую историю") : "Ничего не найдено").font(.title3.bold()).multilineTextAlignment(.center)
            Text(favorites ? "Отметьте произведение звёздочкой в его карточке." : "Найдите произведение с обложкой или перенесите свой текстовый список.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !favorites {
                Button("Найти произведение",systemImage:"magnifyingglass") { showAdd = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Перенести текстовый список") { showImport = true }.frame(minHeight:44)
            }
        }.frame(maxWidth:.infinity).padding(.vertical,36)
    }
}

struct HeroCard: View {
    let entry: Entry
    @Environment(\.dynamicTypeSize) var typeSize
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            NavigationLink { EntryDetail(id:entry.id) } label: {
                CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id).frame(height:typeSize.isAccessibilitySize ? 200 : 240)
                    .overlay(alignment:.topLeading) {
                        Label("Смотрю",systemImage:"play.fill").font(.caption.bold()).padding(.horizontal,10).padding(.vertical,7).background(.black.opacity(0.65),in:Capsule()).foregroundStyle(.white).padding(14)
                    }
            }.buttonStyle(.plain).accessibilityLabel("Открыть \(entry.title)")
            HStack(alignment:.center,spacing:12) {
                NavigationLink { EntryDetail(id:entry.id) } label: {
                    VStack(alignment:.leading,spacing:6) {
                        Text(entry.displayTitle).font(.title3.bold()).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
                        Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain)
                IncrementButton(entry:entry)
            }.padding(16)
        }.background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:24)).clipShape(RoundedRectangle(cornerRadius:24))
    }
}
struct ShelfRow: View {
    let entry: Entry
    @Environment(\.dynamicTypeSize) var typeSize
    var body: some View {
        HStack(alignment:.center,spacing:14) {
            NavigationLink { EntryDetail(id:entry.id) } label: {
                HStack(spacing:14) {
                    CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id).frame(width:76,height:100).clipShape(RoundedRectangle(cornerRadius:13))
                    VStack(alignment:.leading,spacing:7) {
                        Text(entry.displayTitle).font(.headline).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
                        Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        if entry.status != .watching { Text(entry.status.rawValue).font(.caption).foregroundStyle(.blue) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }.buttonStyle(.plain)
            IncrementButton(entry:entry)
        }.accessibilityElement(children:.contain)
    }
}
struct GridCard: View {
    let entry: Entry
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            NavigationLink { EntryDetail(id:entry.id) } label: {
                VStack(alignment:.leading,spacing:10) {
                    CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id).frame(height:220).clipShape(RoundedRectangle(cornerRadius:18))
                    Text(entry.displayTitle).font(.headline).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
                }
            }.buttonStyle(.plain)
            HStack { Text("Серия \(entry.episode)").font(.subheadline).foregroundStyle(.secondary); Spacer(minLength:2); IncrementButton(entry:entry) }
        }
    }
}
struct ReorderView: View {
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var ordered: [Entry] = []
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Перетаскивайте строки за ручки справа. Этот порядок сохранится для режима «Вручную».").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(ordered) { Text($0.title) }.onMove { indices, destination in ordered.move(fromOffsets:indices,toOffset:destination) }
            }.environment(\.editMode,.constant(.active))
                .navigationTitle("Порядок на полке").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Готово") { if store.change({ $0.reorder(ids:ordered.map(\.id)); $0.preferences.sort = .manual }) { dismiss() } } }
                }.onAppear { ordered = store.snapshot.entries }
        }
    }
}
