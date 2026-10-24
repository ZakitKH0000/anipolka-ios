import WidgetKit
import SwiftUI
import UIKit

struct ShelfTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct ShelfProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShelfTimelineEntry { ShelfTimelineEntry(date:Date(),snapshot:.sample) }
    func getSnapshot(in context: Context,completion: @escaping (ShelfTimelineEntry) -> Void) {
        completion(ShelfTimelineEntry(date:Date(),snapshot:WidgetSnapshot.load() ?? (context.isPreview ? .sample : nil)))
    }
    /// The app reloads widgets after every change; the extra entry switches «сегодня» at midnight.
    func getTimeline(in context: Context,completion: @escaping (Timeline<ShelfTimelineEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshot.load()
        let midnight = Calendar.current.startOfDay(for:now.addingTimeInterval(86400))
        completion(Timeline(entries:[ShelfTimelineEntry(date:now,snapshot:snapshot),ShelfTimelineEntry(date:midnight,snapshot:snapshot)],policy:.after(midnight.addingTimeInterval(86400))))
    }
}

extension WidgetSnapshot {
    static var sample: WidgetSnapshot {
        WidgetSnapshot(updatedAt:Date(),items:[
            Item(id:UUID(),title:"Путь за облаками",episode:24,available:2,releaseDays:[],thumbnail:nil),
            Item(id:UUID(),title:"Легенда о красном драконе",episode:11,available:nil,releaseDays:[],thumbnail:nil)
        ],schedule:[:])
    }
}

struct ShelfWidgetView: View {
    let entry: ShelfTimelineEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        content.containerBackground(for:.widget) { Color(red:0.045,green:0.052,blue:0.064) }
    }
    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            let today = snapshot.dueTitles(on:entry.date)
            switch family {
            case .accessoryInline:
                if let first = today.first { Text("Сегодня: \(first)" + (today.count > 1 ? " +\(today.count - 1)" : "")) }
                else if let item = snapshot.items.first { Text("Далее: \(item.title) · \(item.episode + 1)") }
                else { Text("АниПолка") }
            case .accessoryCircular:
                VStack(spacing:0) { Image(systemName:"calendar"); Text("\(today.count)").font(.title3.bold()) }
                    .widgetURL(snapshot.items.first.map { WidgetSnapshot.entryURL($0.id) })
            case .accessoryRectangular:
                VStack(alignment:.leading,spacing:2) {
                    if today.isEmpty, let item = snapshot.items.first {
                        Text("Продолжить").font(.caption2.bold())
                        Text(item.title).font(.headline).lineLimit(1)
                        Text("Серия \(item.episode + 1)").font(.caption)
                    } else if today.isEmpty {
                        Text("АниПолка").font(.headline); Text("Нет историй в процессе").font(.caption)
                    } else {
                        Text("Сегодня выходят").font(.caption2.bold())
                        ForEach(today.prefix(2),id:\.self) { Text($0).font(.caption).lineLimit(1) }
                    }
                }.widgetURL(snapshot.items.first.map { WidgetSnapshot.entryURL($0.id) })
            case .systemMedium:
                VStack(alignment:.leading,spacing:8) {
                    header(today:today)
                    HStack(alignment:.top,spacing:10) {
                        ForEach(snapshot.items.prefix(3)) { item in
                            Link(destination:WidgetSnapshot.entryURL(item.id)) { tile(item,today:today) }
                        }
                    }
                }
            default:
                if let item = snapshot.items.first {
                    VStack(alignment:.leading,spacing:6) {
                        header(today:today)
                        cover(item).frame(maxWidth:.infinity,maxHeight:.infinity)
                        Text(item.title).font(.caption.bold()).lineLimit(1).foregroundStyle(.white)
                        Text(subtitle(item)).font(.caption2).foregroundStyle(.blue)
                    }.widgetURL(WidgetSnapshot.entryURL(item.id))
                } else { empty("Отметьте историю как «Смотрю», и она появится здесь.") }
            }
        } else {
            // Without the shared App Group the widget cannot read the collection at all.
            empty("Откройте АниПолку. Если список не появится, способ подписи не сохранил общую папку для виджета.")
        }
    }
    private func header(today: [String]) -> some View {
        HStack {
            Text("Продолжить").font(.caption.bold()).foregroundStyle(.white)
            Spacer()
            if !today.isEmpty { Label("\(today.count)",systemImage:"calendar").font(.caption2.bold()).foregroundStyle(.orange) }
        }
    }
    private func tile(_ item: WidgetSnapshot.Item,today: [String]) -> some View {
        VStack(alignment:.leading,spacing:4) {
            cover(item).frame(height:70)
            Text(item.title).font(.caption2.bold()).lineLimit(2).foregroundStyle(.white)
            Text(subtitle(item)).font(.caption2).foregroundStyle(today.contains(item.title) ? .orange : .blue)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func subtitle(_ item: WidgetSnapshot.Item) -> String {
        "Серия \(item.episode + 1)" + (item.available.map { " · +\($0)" } ?? "")
    }
    @ViewBuilder private func cover(_ item: WidgetSnapshot.Item) -> some View {
        if let data = item.thumbnail, let image = UIImage(data:data) {
            Image(uiImage:image).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius:8))
        } else {
            RoundedRectangle(cornerRadius:8).fill(LinearGradient(colors:[.blue.opacity(0.4),.indigo.opacity(0.25)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .overlay(Image(systemName:"sparkles.tv").foregroundStyle(.white.opacity(0.7)))
        }
    }
    private func empty(_ text: String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Label("АниПолка",systemImage:"books.vertical.fill").font(.caption.bold()).foregroundStyle(.white)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:WidgetSnapshot.kind,provider:ShelfProvider()) { entry in ShelfWidgetView(entry:entry) }
            .configurationDisplayName("Продолжить просмотр")
            .description("Следующие серии и истории, которые выходят сегодня по вашему расписанию.")
            .supportedFamilies([.systemSmall,.systemMedium,.accessoryRectangular,.accessoryInline,.accessoryCircular])
    }
}

@available(iOS 18.0, *)
struct MarkEpisodeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind:"mark-episode") {
            ControlWidgetButton(action:MarkLatestEpisodeIntent()) { Label("+1 серия",systemImage:"plus.circle") }
        }
        .displayName("АниПолка: +1 серия")
        .description("Отмечает серию в истории, которую вы смотрели последней.")
    }
}

@main struct AniPolkaWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        if #available(iOS 18.0, *) { MarkEpisodeControl() }
    }
}
