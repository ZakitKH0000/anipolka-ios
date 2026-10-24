import Foundation

/// Small read-only summary that the app writes for its widgets. Compiled into both targets.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var episode: Int
        var available: Int?
        var releaseDays: [Int]
        var thumbnail: Data?
    }
    static let appGroup = "group.com.zakitkh.anipolka"
    static let kind = "continue-watching"
    var updatedAt: Date
    /// Titles in progress, most recently watched first.
    var items: [Item]
    /// Every title in the user's schedule, not only the ones in `items`.
    var schedule: [String:[String]]
    func dueTitles(on date: Date, calendar: Calendar = .current) -> [String] {
        schedule[String(calendar.component(.weekday,from:date))] ?? []
    }
    /// Nil when the signing tool did not keep the shared App Group; the widget then explains it.
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:appGroup)?.appendingPathComponent("widget.json")
    }
    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf:url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self,from:data)
    }
    static func entryURL(_ id: UUID) -> URL { URL(string:"anipolka://entry/\(id.uuidString)")! }
}
