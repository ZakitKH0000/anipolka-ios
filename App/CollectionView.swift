import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var network: NetworkService
    @EnvironmentObject var assistant: ShelfAssistant
    @State private var opened: OpenedEntry?
    private var pendingLink: Binding<OpenedLink?> {
        Binding(get:{ store.pendingLink.map(OpenedLink.init) },set:{ if $0 == nil { store.pendingLink = nil } })
    }
    var body: some View {
        TabView {
            ShelfView().tabItem { Label("Коллекция",systemImage:"books.vertical.fill") }
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
        // Widgets open a title through anipolka://entry/<id>.
        .onOpenURL { url in
            guard url.scheme == "anipolka", url.host == "entry", let id = UUID(uuidString:url.lastPathComponent),
                  store.snapshot.entries.contains(where:{$0.id == id}) else { return }
            opened = OpenedEntry(id:id)
        }
        .sheet(item:$opened) { item in
            NavigationStack { EntryDetail(id:item.id).toolbar { ToolbarItem(placement:.cancellationAction) { Button("Готово") { opened = nil } } } }
                .environmentObject(store).environmentObject(network).environmentObject(assistant)
        }
        .sheet(item:pendingLink) { link in LinkInboxView(url:link.url).environmentObject(store).environmentObject(network).environmentObject(assistant) }
        .alert("Не удалось выполнить действие",isPresented: Binding(get:{store.error != nil},set:{if !$0 { store.error = nil }})) { Button("Понятно",role:.cancel) { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

struct ShelfView: View {
    @EnvironmentObject var store: ShelfStore
    @State private var query = ""
    @State private var status: WatchStatus? = nil
    @State private var favoritesOnly = false
    @State private var tag: String? = nil
    @State private var behind = false
    @State private var dub: String? = nil
    @State private var showAdd = false
    @State private var showReorder = false
    @State private var showImport = false
    @State private var showSuggestion = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var prefs: Preferences { store.snapshot.preferences }
    private var filtering: Bool { !query.isEmpty || status != nil || favoritesOnly || tag != nil || behind || dub != nil }
    private var entries: [Entry] { store.snapshot.visible(query:query,status:status,favorites:favoritesOnly,tag:tag,behindOnly:behind,dub:dub) }
    /// The title watched last, regardless of sorting, so «Продолжить» never depends on the list order.
    private var hero: Entry? { ReleasePlanner.continuing(store.snapshot.entries,limit:1).first }
    private var todayEntries: [Entry] {
        let all = store.snapshot.entries
        let releases = ReleasePlanner.due(all,weekday:ReleasePlanner.weekday(of:Date()))
        let premieres = PremierePlanner.upcoming(all).filter { $0.premiereDate.map(Calendar.current.isDateInToday) ?? false }
        return releases + premieres.filter { p in !releases.contains { $0.id == p.id } }
    }
    private var headline: String {
        var parts = [Greeting.text()]
        let watching = store.snapshot.entries.filter { $0.status == .watching }.count
        if !todayEntries.isEmpty { parts.append("сегодня выходит: \(todayEntries.count)") }
        else if watching > 0 { parts.append("в процессе: \(watching)") }
        return parts.joined(separator:" · ")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text(headline).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal,20).padding(.top,2)
                    if let failure = store.loadFailure { Label(failure,systemImage:"exclamationmark.triangle").foregroundStyle(.orange).padding().background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:18)).padding(.horizontal,20) }
                    if !filtering, prefs.showContinue, let entry = hero { HeroCard(entry:entry).padding(.horizontal,20) }
                    if !filtering, !todayEntries.isEmpty { TodayRow(entries:todayEntries) }
                    filters
                    HStack {
                        Text(favoritesOnly ? "Избранное" : "Мой список").font(.title2.bold())
                        Text("\(entries.count)").font(.title3).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Picker("Сортировка",selection:store.preference(\.sort)) { ForEach(ShelfSort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                            Picker("Вид коллекции",selection:store.preference(\.layout)) { ForEach(Layout.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                            Toggle("Группы по статусам",isOn:store.preference(\.shelves))
                            Button("Изменить порядок",systemImage:"line.3.horizontal") { showReorder = true }
                            Button("Импорт текстового списка",systemImage:"text.badge.plus") { showImport = true }
                            Button("Что посмотреть?",systemImage:"dice") { showSuggestion = true }
                            ShareLink(item:ShelfExport.text(entries),subject:Text("Мой список АниПолки")) { Label("Поделиться списком текстом",systemImage:"square.and.arrow.up") }
                        } label: { Image(systemName:"slider.horizontal.3").frame(width:44,height:44) }.accessibilityLabel("Вид и сортировка")
                    }.padding(.horizontal,20)
                    content.padding(.horizontal,20)
                    if store.demo { Text("Предпросмотр · тестовые названия и иллюстрации").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20) }
                }.padding(.bottom,24)
            }
            .background(ShelfDesign.background)
            .navigationTitle("Коллекция")
            .searchable(text:$query,placement:.navigationBarDrawer(displayMode:.automatic),prompt:"Найти в коллекции")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) { Button { showAdd = true } label: { Image(systemName:"plus").font(.title3) }.accessibilityLabel("Добавить произведение").accessibilityIdentifier("add") }
            }
            .sheet(isPresented:$showAdd) { AddWizardView() }
            .sheet(isPresented:$showReorder) { ReorderView() }
            .sheet(isPresented:$showImport) { TextImportView() }
            .sheet(isPresented:$showSuggestion) { SuggestionView() }
        }
    }
    @ViewBuilder private var content: some View {
        if entries.isEmpty { emptyState }
        else if prefs.shelves && !filtering {
            VStack(alignment:.leading,spacing:26) {
                ForEach(ShelfSections.make(entries)) { section in
                    VStack(alignment:.leading,spacing:12) {
                        HStack(alignment:.firstTextBaseline) { Text(section.title).font(.title3.bold()); Text("\(section.entries.count)").foregroundStyle(.secondary) }
                        PosterGrid(entries:section.entries)
                    }
                }
            }
        }
        else if prefs.layout == .grid { PosterGrid(entries:entries) }
        else {
            LazyVStack(spacing:0) {
                ForEach(entries) { entry in
                    ShelfRow(entry:entry)
                    Divider().padding(.leading,90).padding(.vertical,12)
                }
            }
        }
    }
    private var filters: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:8) {
                chip("Все",selected:!filtering) { query = ""; status = nil; favoritesOnly = false; tag = nil; behind = false; dub = nil }
                chip("★ Избранное",selected:favoritesOnly) { favoritesOnly.toggle() }.accessibilityIdentifier("filter-favorites")
                ForEach(WatchStatus.allCases) { value in chip(value.rawValue,selected:status == value) { status = status == value ? nil : value } }
                if behind || store.snapshot.entries.contains(where:{ Backlog.available($0) != nil }) {
                    chip("Есть новые серии",selected:behind) { behind.toggle() }.accessibilityIdentifier("filter-behind")
                }
                ForEach(Tags.all(store.snapshot.entries),id:\.self) { value in chip("#\(value)",selected:tag == value) { tag = tag == value ? nil : value } }
                ForEach(Dubs.inUse(store.snapshot.entries,favorites:prefs.favoriteDubs),id:\.self) { value in chip("Озвучка: \(value)",selected:dub == value) { dub = dub == value ? nil : value } }
            }.padding(.horizontal,20).padding(.vertical,2)
        }
    }
    private func chip(_ title: String,selected: Bool,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).padding(.horizontal,15).frame(minHeight:44)
                .background(selected ? Color.blue.opacity(0.18) : Color.secondary.opacity(0.07),in:Capsule())
                .foregroundStyle(selected ? Color.blue : Color.primary)
                .overlay(Capsule().stroke(selected ? Color.blue.opacity(0.5) : .clear))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private var emptyState: some View {
        VStack(spacing:16) {
            Image(systemName:filtering ? "magnifyingglass" : "books.vertical").font(.system(size:48,weight:.light)).foregroundStyle(.blue)
            Text(filtering ? "Ничего не найдено" : "Ваша полка ждёт первую историю").font(.title3.bold()).multilineTextAlignment(.center)
            Text(filtering ? "Измените поиск или сбросьте фильтры: кнопка «Все»." : "Найдите произведение с обложкой или перенесите свой текстовый список.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !filtering {
                Button("Добавить историю",systemImage:"plus") { showAdd = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Перенести текстовый список") { showImport = true }.frame(minHeight:44)
            }
        }.frame(maxWidth:.infinity).padding(.vertical,36)
    }
}

/// Thin progress line used on covers: watched episodes out of the source's latest episode.
struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(Color.blue).frame(width:max(4,geo.size.width * min(max(value,0),1)))
            }
        }.frame(height:4).accessibilityHidden(true)
    }
}

struct CoverBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName:symbol).font(.caption.bold()).foregroundStyle(tint).frame(width:26,height:26)
            .background(.black.opacity(0.6),in:Circle()).accessibilityHidden(true)
    }
}

struct HeroCard: View {
    let entry: Entry
    @Environment(\.dynamicTypeSize) var typeSize
    var body: some View {
        ZStack(alignment:.bottomTrailing) {
            NavigationLink { EntryDetail(id:entry.id) } label: {
                CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id)
                    .frame(height:typeSize.isAccessibilitySize ? 280 : 320)
                    .overlay(alignment:.topLeading) {
                        Label("Продолжить",systemImage:"play.fill").font(.caption.bold()).padding(.horizontal,10).padding(.vertical,7).background(.black.opacity(0.6),in:Capsule()).foregroundStyle(.white).padding(14)
                    }
                    .overlay(alignment:.bottom) { info }
                    .clipShape(RoundedRectangle(cornerRadius:28,style:.continuous))
            }.buttonStyle(.plain).accessibilityLabel("Открыть \(entry.title)")
            IncrementButton(entry:entry).padding(14)
        }
    }
    private var info: some View {
        VStack(alignment:.leading,spacing:6) {
            Text(entry.title).font(.title2.bold()).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing:8) {
                Text("Серия \(entry.episode)").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.9)).contentTransition(.numericText(value:Double(entry.episode))).animation(.snappy,value:entry.episode)
                if let n = Backlog.available(entry) { Text("+\(n)").font(.caption.bold()).padding(.horizontal,8).padding(.vertical,3).background(Color.blue,in:Capsule()).foregroundStyle(.white) }
                else if Backlog.caughtUp(entry) { Label("Догнал",systemImage:"hourglass").font(.caption).foregroundStyle(.white.opacity(0.85)) }
            }
            if let progress = Backlog.progress(entry) { ProgressLine(value:progress) }
        }
        .padding(.leading,18).padding(.trailing,86).padding(.bottom,20).padding(.top,48)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(LinearGradient(colors:[.clear,.black.opacity(0.82)],startPoint:.top,endPoint:.bottom))
    }
}

/// «Сегодня выходит»: titles from the user's own release days and premieres.
struct TodayRow: View {
    let entries: [Entry]
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.firstTextBaseline) { Text("Сегодня выходит").font(.title3.bold()); Text("\(entries.count)").foregroundStyle(.secondary) }.padding(.horizontal,20)
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:12) {
                    ForEach(entries) { entry in
                        NavigationLink { EntryDetail(id:entry.id) } label: {
                            HStack(spacing:10) {
                                CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id).frame(width:44,height:62).clipShape(RoundedRectangle(cornerRadius:9,style:.continuous))
                                VStack(alignment:.leading,spacing:3) {
                                    Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                                    Text("Следующая: \(entry.episode + 1)").font(.caption).foregroundStyle(.orange)
                                }
                                Spacer(minLength:0)
                            }.padding(10).frame(width:240,alignment:.leading).background(ShelfDesign.surface,in:RoundedRectangle(cornerRadius:18,style:.continuous))
                        }.buttonStyle(.plain).accessibilityLabel("\(entry.title), сегодня выходит серия \(entry.episode + 1)")
                    }
                }.padding(.horizontal,20)
            }
        }
    }
}

struct PosterGrid: View {
    let entries: [Entry]
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let columns = Array(repeating:GridItem(.flexible(),spacing:14,alignment:.top),count:typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns:columns,alignment:.leading,spacing:22) {
            ForEach(entries) { entry in PosterCard(entry:entry) }
        }
    }
}

/// Every card has the same height: a 2:3 cover, a two-line title and one action row.
/// Badges sit on the cover, so nothing under the title can wrap or be cut off.
struct PosterCard: View {
    let entry: Entry
    private var releasesToday: Bool { (entry.releaseDays ?? []).contains(ReleasePlanner.weekday(of:Date())) && (entry.status == .watching || entry.status == .planned) }
    private var spoken: String {
        var parts = [entry.title,"серия \(entry.episode)"]
        if let n = Backlog.available(entry) { parts.append("доступно ещё \(n)") }
        if Backlog.caughtUp(entry) { parts.append("догнал") }
        if entry.favorite { parts.append("избранное") }
        if releasesToday { parts.append("сегодня выход") }
        if let rating = entry.rating { parts.append("оценка \(rating) из 5") }
        return parts.joined(separator:", ")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            NavigationLink { EntryDetail(id:entry.id) } label: {
                VStack(alignment:.leading,spacing:8) {
                    Color.clear.aspectRatio(2.0 / 3.0,contentMode:.fit)
                        .overlay { CoverView(data:entry.coverData,url:entry.coverURL,entryID:entry.id) }
                        .overlay(alignment:.topLeading) {
                            HStack(spacing:5) {
                                if entry.favorite { CoverBadge(symbol:"star.fill",tint:.yellow) }
                                if releasesToday { CoverBadge(symbol:"calendar",tint:.orange) }
                                if Backlog.caughtUp(entry) { CoverBadge(symbol:"hourglass",tint:.white) }
                            }.padding(8)
                        }
                        .overlay(alignment:.topTrailing) {
                            if let n = Backlog.available(entry) {
                                Text("+\(n)").font(.caption.bold()).padding(.horizontal,9).padding(.vertical,5).background(Color.blue,in:Capsule()).foregroundStyle(.white).padding(8)
                            }
                        }
                        .overlay(alignment:.bottom) {
                            if let progress = Backlog.progress(entry) { ProgressLine(value:progress).padding(.horizontal,10).padding(.bottom,10) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius:20,style:.continuous))
                    Text(entry.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        .lineLimit(2,reservesSpace:true).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.buttonStyle(.plain).accessibilityLabel(spoken)
            HStack(spacing:6) {
                Text("Серия \(entry.episode)").font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText(value:Double(entry.episode))).animation(.snappy,value:entry.episode)
                Spacer(minLength:2)
                IncrementButton(entry:entry)
            }
        }
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
                        Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary).contentTransition(.numericText(value:Double(entry.episode))).animation(.snappy,value:entry.episode)
                        if entry.status != .watching { Text(entry.status.rawValue).font(.caption).foregroundStyle(.blue) }
                        EntryBadges(entry:entry)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
            }.buttonStyle(.plain)
            IncrementButton(entry:entry)
        }.accessibilityElement(children:.contain)
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
