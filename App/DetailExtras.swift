import SwiftUI
import UIKit

/// Average cover colour, brightened enough to work as an accent on dark and light backgrounds.
enum CoverPalette {
    private static var cache: [String:UIColor] = [:]
    static func accent(_ data: Data?) -> Color? {
        guard let data else { return nil }
        let key = "\(data.count)-\(data.hashValue)"
        if let cached = cache[key] { return Color(uiColor:cached) }
        guard let image = UIImage(data:data), let cg = image.cgImage else { return nil }
        var pixel = [UInt8](repeating:0,count:4)
        guard let context = CGContext(data:&pixel,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg,in:CGRect(x:0,y:0,width:1,height:1))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red:CGFloat(pixel[0]) / 255,green:CGFloat(pixel[1]) / 255,blue:CGFloat(pixel[2]) / 255,alpha:1).getHue(&hue,saturation:&saturation,brightness:&brightness,alpha:&alpha)
        let color = UIColor(hue:hue,saturation:min(max(saturation,0.45),0.85),brightness:min(max(brightness,0.7),0.9),alpha:1)
        cache[key] = color
        return Color(uiColor:color)
    }
}

/// Blurred cover behind the detail screen.
struct CoverAtmosphere: View {
    let data: Data?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment:.top) {
            ShelfDesign.background
            if !reduceTransparency, let data, let image = UIImage(data:data) {
                Image(uiImage:image).resizable().scaledToFill().frame(height:520).clipped().blur(radius:60).opacity(0.5)
                    .overlay(LinearGradient(colors:[.clear,ShelfDesign.background],startPoint:.center,endPoint:.bottom))
            }
        }.ignoresSafeArea()
    }
}

struct ResumeCard: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @State private var addingNote = false
    @State private var editing: EpisodeNote?
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Где остановился").font(.headline); Spacer(); Button("Отметить",systemImage:"bookmark") { addingNote = true }.font(.subheadline).accessibilityIdentifier("add-note") }
            if let point = entry.resumePoint {
                VStack(alignment:.leading,spacing:4) {
                    Text("Серия \(point.episode)" + (point.time.isEmpty ? "" : " · \(point.time)")).font(.title3.bold())
                    if !point.text.isEmpty { Text(point.text).font(.subheadline).textSelection(.enabled) }
                    Text(point.createdAt.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                }
                let older = (entry.notes ?? []).filter { $0.id != point.id }.sorted { $0.createdAt > $1.createdAt }
                if !older.isEmpty {
                    DisclosureGroup("Другие заметки: \(older.count)") {
                        VStack(alignment:.leading,spacing:10) {
                            ForEach(older) { note in
                                VStack(alignment:.leading,spacing:2) {
                                    Text("Серия \(note.episode)" + (note.time.isEmpty ? "" : " · \(note.time)")).font(.subheadline.bold())
                                    if !note.text.isEmpty { Text(note.text).font(.subheadline) }
                                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                    .contextMenu { Button("Изменить",systemImage:"pencil") { editing = note }; Button("Удалить",systemImage:"trash",role:.destructive) { remove(note.id) } }
                            }
                        }.padding(.top,6)
                    }.font(.subheadline)
                }
            } else {
                Text("Сохраните серию, минуту и заметку, например «серия 25 · 14:30 · смотрю в озвучке ПВА ШОУ».").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16).background(ShelfDesign.surface.opacity(0.85),in:RoundedRectangle(cornerRadius:20))
        .contextMenu { if let point = entry.resumePoint { Button("Изменить",systemImage:"pencil") { editing = point }; Button("Удалить",systemImage:"trash",role:.destructive) { remove(point.id) } } }
        .sheet(isPresented:$addingNote) { NoteEditor(entryID:entry.id,note:EpisodeNote(episode:entry.episode + 1)) }
        .sheet(item:$editing) { note in NoteEditor(entryID:entry.id,note:note) }
    }
    private func remove(_ id: UUID) {
        _ = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entry.id}) else { return }
            state.entries[i].notes?.removeAll { $0.id == id }
            if state.entries[i].notes?.isEmpty == true { state.entries[i].notes = nil }
        }
    }
}

struct NoteEditor: View {
    let entryID: UUID
    @State var note: EpisodeNote
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Серия \(note.episode)",value:$note.episode,in:0...1_000_000)
                    TextField("Минута, например 14:30",text:$note.time).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("note-time")
                    TextField("Заметка: озвучка, плейлист, что запомнилось",text:$note.text,axis:.vertical).lineLimit(2...8).accessibilityIdentifier("note-text")
                } footer: { Text("Последняя заметка показывается в карточке как «Где остановился».") }
                if let problem { Text(problem).foregroundStyle(.orange) }
            }
            .navigationTitle("Где остановился").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Сохранить") { save() }.accessibilityIdentifier("save-note") }
            }
        }
    }
    private func save() {
        guard let time = EpisodeTime.normalized(note.time) else { problem = "Минуту укажите как 14:30 или 1:02:03."; return }
        note.time = time; note.text = String(note.text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(2000))
        let saved = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entryID}) else { return }
            if let j = state.entries[i].notes?.firstIndex(where:{$0.id == note.id}) { state.entries[i].notes?[j] = note }
            else { var fresh = note; fresh.createdAt = Date(); state.entries[i].addNote(fresh) }
        }
        if saved { dismiss() }
    }
}

struct WatchLinksSection: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @State private var adding = false
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Где смотрю").font(.headline); Spacer(); Button("Добавить",systemImage:"link.badge.plus") { adding = true }.font(.subheadline).accessibilityIdentifier("add-link") }
            if let links = entry.links, !links.isEmpty {
                ForEach(links) { link in
                    if let url = validWebURL(link.url) {
                        Link(destination:url) {
                            VStack(alignment:.leading,spacing:2) {
                                Text(link.label).font(.subheadline.bold()).foregroundStyle(.primary)
                                Text(url.host ?? link.url).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                        .contextMenu {
                            Button("Сделать основной",systemImage:"star") { change { $0.promoteLink(link.id) } }
                            Button("Удалить",systemImage:"trash",role:.destructive) { change { e in e.links?.removeAll { $0.id == link.id }; if e.links?.isEmpty == true { e.links = nil } } }
                        }
                    }
                }
                Text("Удерживайте ссылку, чтобы сделать её основной или удалить.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Площадки, плейлисты и озвучки, где вы смотрите эту историю. Основная ссылка открывается кнопкой «Открыть страницу просмотра».").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(16).background(ShelfDesign.surface.opacity(0.85),in:RoundedRectangle(cornerRadius:20))
        .sheet(isPresented:$adding) { LinkEditor(entryID:entry.id) }
    }
    private func change(_ block: @escaping (inout Entry) -> Void) {
        _ = store.change { state in if let i = state.entries.firstIndex(where:{$0.id == entry.id}) { block(&state.entries[i]) } }
    }
}

struct LinkEditor: View {
    let entryID: UUID
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var label = ""
    @State private var address = ""
    @State private var primary = false
    @State private var problem: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название: AniVibe · ПВА ШОУ, VK · плейлист 2 сезона",text:$label,axis:.vertical).accessibilityIdentifier("link-label")
                    TextField("https://…",text:$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("link-url")
                    Toggle("Сделать основной",isOn:$primary)
                }
                if let problem { Text(problem).foregroundStyle(.orange) }
            }
            .navigationTitle("Где смотрю").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Сохранить") { save() }.accessibilityIdentifier("save-link") }
            }
        }
    }
    private func save() {
        let url = address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let parsed = validWebURL(url), url.count <= 4000 else { problem = "Ссылка должна начинаться с http:// или https://."; return }
        var name = String(label.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100))
        if name.isEmpty { name = parsed.host ?? "Ссылка" }
        let saved = store.change { state in
            guard let i = state.entries.firstIndex(where:{$0.id == entryID}), (state.entries[i].links?.count ?? 0) < WatchLink.limit else { return }
            let link = WatchLink(label:name,url:url)
            state.entries[i].links = (state.entries[i].links ?? []) + [link]
            if primary { state.entries[i].promoteLink(link.id) }
        }
        if saved { dismiss() }
    }
}

struct ShelvesView: View {
    let entries: [Entry]
    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            ForEach(ShelfSections.make(entries)) { section in
                VStack(alignment:.leading,spacing:12) {
                    HStack(alignment:.firstTextBaseline) { Text(section.title).font(.title3.bold()); Text("\(section.entries.count)").foregroundStyle(.secondary) }
                    ScrollView(.horizontal,showsIndicators:false) {
                        LazyHStack(alignment:.top,spacing:14) {
                            ForEach(section.entries) { entry in GridCard(entry:entry).frame(width:150) }
                        }
                    }.accessibilityIdentifier("shelf-\(section.title)")
                }
            }
        }
    }
}

struct YearCardView: View {
    let summary: YearSummary
    let covers: [Data]
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("АниПолка \(String(summary.year))").font(.system(size:34,weight:.heavy)).foregroundStyle(.white)
            HStack(spacing:10) {
                ForEach(Array(covers.prefix(4).enumerated()),id:\.offset) { _, data in
                    if let image = UIImage(data:data) { Image(uiImage:image).resizable().scaledToFill().frame(width:70,height:96).clipShape(RoundedRectangle(cornerRadius:10)) }
                }
            }
            HStack(spacing:22) {
                stat("\(summary.episodes)",episodesWord(summary.episodes))
                stat("\(summary.activeDays)","дней с просмотром")
                stat("\(summary.completed.count)","завершено")
            }
            if let best = summary.mostWatched { Text("Больше всего: \(best)").font(.headline).foregroundStyle(.white) }
            if !summary.topRated.isEmpty { Text("★★★★★ " + summary.topRated.prefix(3).joined(separator:" · ")).font(.subheadline).foregroundStyle(.yellow) }
            Text("Посчитано по отметкам в АниПолке").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(24).frame(width:360,alignment:.leading)
        .background(LinearGradient(colors:[Color(red:0.06,green:0.12,blue:0.3),Color(red:0.25,green:0.1,blue:0.35)],startPoint:.topLeading,endPoint:.bottomTrailing))
    }
    private func stat(_ value: String,_ title: String) -> some View {
        VStack(alignment:.leading,spacing:2) { Text(value).font(.title.bold()).foregroundStyle(.white); Text(title).font(.caption).foregroundStyle(.white.opacity(0.75)) }
    }
}

struct YearCardSection: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let year = Calendar.current.component(.year,from:Date())
        let summary = YearSummary(snapshot:store.snapshot,year:year)
        let covers = store.snapshot.entries.filter { summary.topRated.contains($0.title) || $0.title == summary.mostWatched }.compactMap(\.coverData)
        let card = YearCardView(summary:summary,covers:covers)
        Section {
            card.frame(maxWidth:.infinity).clipShape(RoundedRectangle(cornerRadius:20)).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            if let image = render(card) {
                ShareLink(item:image,preview:SharePreview("АниПолка \(String(year))",image:image)) { Label("Поделиться карточкой",systemImage:"square.and.arrow.up") }
            }
        } header: { Text("Итоги года") }
    }
    @MainActor private func render(_ card: YearCardView) -> Image? {
        let renderer = ImageRenderer(content:card); renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage:$0) }
    }
}

struct AppIconPicker: View {
    private struct Choice { let name: String?; let title: String; let preview: String }
    private let icons = [Choice(name:nil,title:"Синяя",preview:"IconPreviewDefault"),Choice(name:"AppIconLight",title:"Светлая",preview:"IconPreviewLight"),Choice(name:"AppIconDonghua",title:"Дунхуа",preview:"IconPreviewDonghua")]
    @State private var current = UIApplication.shared.alternateIconName
    @State private var problem: String?
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Иконка приложения")
            HStack(spacing:16) {
                ForEach(icons,id:\.title) { icon in
                    Button { choose(icon.name) } label: {
                        VStack(spacing:6) {
                            Image(icon.preview).resizable().frame(width:58,height:58).clipShape(RoundedRectangle(cornerRadius:13))
                                .overlay(RoundedRectangle(cornerRadius:13).stroke(current == icon.name ? Color.blue : .clear,lineWidth:3))
                            Text(icon.title).font(.caption).foregroundStyle(current == icon.name ? Color.blue : Color.primary)
                        }
                    }.buttonStyle(.borderless).accessibilityLabel("Иконка \(icon.title)").accessibilityAddTraits(current == icon.name ? [.isSelected] : [])
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical,4)
    }
    private func choose(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else { problem = "Эта установка не поддерживает смену иконки."; return }
        UIApplication.shared.setAlternateIconName(name) { error in
            Task { @MainActor in
                if let error { problem = "Иконку не удалось сменить: \(error.localizedDescription)" } else { current = name; problem = nil }
            }
        }
    }
}

struct WeekView: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        List {
            ForEach(WeekPlan.days(store.snapshot.entries)) { day in
                Section {
                    if day.releases.isEmpty && day.premieres.isEmpty { Text("Ничего не отмечено").foregroundStyle(.secondary) }
                    ForEach(day.premieres,id:\.self) { Label($0,systemImage:"sparkles").foregroundStyle(.orange) }
                    ForEach(day.releases,id:\.self) { Label($0,systemImage:"play.tv") }
                } header: {
                    Text(Calendar.current.isDateInToday(day.date) ? "Сегодня" : day.date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                }
            }
            Section {
                Text("Дни выхода указываются в карточке: «Изменить» → «Дни выхода и метки». Там же — дата премьеры.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Неделя")
    }
}

struct RelatedPartsSection: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let related = Relations.related(of:entry,in:store.snapshot.entries)
        if !related.isEmpty {
            VStack(alignment:.leading,spacing:8) {
                Text("Связанные части").font(.headline)
                ForEach(related) { part in
                    NavigationLink { EntryDetail(id:part.id) } label: {
                        HStack(spacing:12) {
                            CoverView(data:part.coverData,url:part.coverURL,entryID:part.id).frame(width:44,height:58).clipShape(RoundedRectangle(cornerRadius:8))
                            VStack(alignment:.leading,spacing:2) { Text(part.title).font(.subheadline.bold()).foregroundStyle(.primary); Text(part.subtitle).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(16).background(ShelfDesign.surface.opacity(0.85),in:RoundedRectangle(cornerRadius:20))
        }
    }
}

struct RelatedPicker: View {
    let entryID: UUID
    @Binding var selected: Set<UUID>
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List(store.snapshot.visible(query:query).filter { $0.id != entryID }) { other in
                Button {
                    if selected.contains(other.id) { selected.remove(other.id) }
                    else if selected.count < Relations.limit { selected.insert(other.id) }
                } label: {
                    HStack {
                        VStack(alignment:.leading,spacing:2) { Text(other.title).foregroundStyle(.primary); Text(other.subtitle).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if selected.contains(other.id) { Image(systemName:"checkmark").foregroundStyle(.blue) }
                    }
                }.accessibilityAddTraits(selected.contains(other.id) ? [.isSelected] : [])
            }
            .searchable(text:$query,prompt:"Найти историю")
            .navigationTitle("Связанные части").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
