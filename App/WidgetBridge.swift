import UIKit
import WidgetKit

@MainActor final class WidgetBridge {
    static let shared = WidgetBridge()
    private var published: WidgetSnapshot?
    private var thumbnails: [UUID:(key: String,data: Data?)] = [:]
    var available: Bool { WidgetSnapshot.fileURL != nil }
    func publish(_ snapshot: Snapshot) {
        guard let url = WidgetSnapshot.fileURL else { return }
        let items = ReleasePlanner.continuing(snapshot.entries,limit:4).map { e in
            WidgetSnapshot.Item(id:e.id,title:e.title,episode:e.episode,available:Backlog.available(e),releaseDays:e.releaseDays ?? [],thumbnail:thumbnail(e))
        }
        var schedule: [String:[String]] = [:]
        for day in 1...7 {
            let titles = ReleasePlanner.due(snapshot.entries,weekday:day).map(\.title)
            if !titles.isEmpty { schedule[String(day)] = titles }
        }
        if let published, published.items == items, published.schedule == schedule { return }
        let next = WidgetSnapshot(updatedAt:Date(),items:items,schedule:schedule)
        guard let data = try? JSONEncoder().encode(next), (try? data.write(to:url,options:.atomic)) != nil else { return }
        published = next
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// Widgets have a tight memory limit, so covers are reduced to small JPEG thumbnails.
    private func thumbnail(_ entry: Entry) -> Data? {
        guard let data = entry.coverData else { return nil }
        let key = "\(data.count)-\(data.hashValue)"
        if let cached = thumbnails[entry.id], cached.key == key { return cached.data }
        var result: Data?
        if let image = UIImage(data:data), image.size.width > 0, image.size.height > 0 {
            let size = CGSize(width:150,height:200)
            let scale = max(size.width / image.size.width,size.height / image.size.height)
            let drawn = CGSize(width:image.size.width * scale,height:image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            result = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                image.draw(in:CGRect(x:(size.width - drawn.width) / 2,y:(size.height - drawn.height) / 2,width:drawn.width,height:drawn.height))
            }.jpegData(compressionQuality:0.75)
        }
        thumbnails[entry.id] = (key,result)
        return result
    }
}
