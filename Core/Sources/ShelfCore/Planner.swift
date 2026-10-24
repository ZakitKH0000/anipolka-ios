import Foundation

/// One progress step recorded by the app. Only used for local statistics.
public struct WatchMark: Codable, Equatable {
    public static let limit = 20_000
    public var entryID: UUID
    public var at: Date
    public var episodes: Int
    public init(entryID: UUID, at: Date, episodes: Int) { self.entryID = entryID; self.at = at; self.episodes = episodes }
}

public enum Tags {
    public static let limit = 20
    public static let maxLength = 40
    /// Comma-separated user labels; duplicates are dropped case-insensitively, order is kept.
    public static func parse(_ text: String) -> [String] {
        var result: [String] = []
        for part in text.components(separatedBy: CharacterSet(charactersIn: ",;#\n")) {
            let tag = String(part.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, result.count < limit, !contains(result, tag) else { continue }
            result.append(tag)
        }
        return result
    }
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    public static func all(_ entries: [Entry]) -> [String] {
        var result: [String] = []
        for entry in entries { for tag in entry.tags ?? [] where !contains(result, tag) { result.append(tag) } }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum Backlog {
    /// A larger gap usually means the source numbers seasons differently from the user.
    public static let plausibleGap = 99
    public static func latest(_ entry: Entry) -> Int? {
        (entry.subscriptions ?? []).filter(\.enabled).compactMap(\.lastEpisode).max()
    }
    /// Episodes available in connected sources beyond the user's own mark.
    public static func available(_ entry: Entry) -> Int? {
        guard entry.status == .watching || entry.status == .planned, let latest = latest(entry),
              latest > entry.episode, latest - entry.episode <= plausibleGap else { return nil }
        return latest - entry.episode
    }
}

public enum ReleasePlanner {
    /// Monday first, as on a Russian calendar; values are `Calendar` weekdays.
    public static let displayOrder = [2, 3, 4, 5, 6, 7, 1]
    public static func shortName(_ weekday: Int) -> String {
        guard (1...7).contains(weekday) else { return "" }
        return ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"][weekday - 1]
    }
    public static func days(_ entry: Entry) -> String {
        displayOrder.filter { (entry.releaseDays ?? []).contains($0) }.map(shortName).joined(separator: ", ")
    }
    public static func weekday(of date: Date, calendar: Calendar = .current) -> Int { calendar.component(.weekday, from: date) }
    public static func due(_ entries: [Entry], weekday: Int) -> [Entry] {
        entries.filter { ($0.status == .watching || $0.status == .planned) && ($0.releaseDays ?? []).contains(weekday) }
    }
    public static func digestBody(_ titles: [String]) -> String {
        let shown = titles.prefix(4).map { "«\($0)»" }
        guard let last = shown.last else { return "" }
        if titles.count > 4 { return shown.joined(separator: ", ") + " и ещё \(titles.count - 4)" }
        return shown.count == 1 ? last : shown.dropLast().joined(separator: ", ") + " и " + last
    }
    /// Titles in progress, most recently watched first.
    public static func continuing(_ entries: [Entry], limit: Int) -> [Entry] {
        Array(entries.filter { $0.status == .watching }.sorted { ($0.watchedAt ?? $0.updatedAt) > ($1.watchedAt ?? $1.updatedAt) }.prefix(limit))
    }
}

public struct WatchStats: Equatable {
    public var lastWeek = 0
    public var lastMonth = 0
    public var thisYear = 0
    public var trackingSince: Date?
    public var totalEpisodes = 0
    public var byStatus: [WatchStatus: Int] = [:]
    public var completedThisYear = 0
    public var averageRating: Double?
    public var topRated: [String] = []
    public init(snapshot: Snapshot, now: Date = Date(), calendar: Calendar = .current) {
        let marks = snapshot.history ?? []
        let year = calendar.component(.year, from: now)
        for mark in marks where mark.at <= now {
            let age = now.timeIntervalSince(mark.at)
            if age < 7 * 86400 { lastWeek += mark.episodes }
            if age < 30 * 86400 { lastMonth += mark.episodes }
            if calendar.component(.year, from: mark.at) == year { thisYear += mark.episodes }
        }
        trackingSince = marks.map(\.at).min()
        totalEpisodes = snapshot.entries.reduce(0) { $0 + $1.episode }
        for entry in snapshot.entries { byStatus[entry.status, default: 0] += 1 }
        completedThisYear = snapshot.entries.filter { $0.completedAt.map { calendar.component(.year, from: $0) == year } ?? false }.count
        let ratings = snapshot.entries.compactMap(\.rating)
        averageRating = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        topRated = snapshot.entries.filter { $0.rating == 5 }.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension Snapshot {
    public mutating func recordWatch(entryID: UUID, episodes: Int, at: Date) {
        guard episodes > 0 else { return }
        var marks = history ?? []
        marks.append(WatchMark(entryID: entryID, at: at, episodes: min(episodes, 1_000_000)))
        if marks.count > WatchMark.limit { marks.removeFirst(marks.count - WatchMark.limit) }
        history = marks
    }
    /// Stores an edited entry; progress made in the editor counts in statistics and
    /// switching to «Завершено» remembers the date.
    public mutating func save(_ edited: Entry, now: Date = Date()) {
        var entry = edited
        if entry.status != .completed { entry.completedAt = nil }
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            let old = entries[i]
            if entry.status == .completed, old.status != .completed, entry.completedAt == nil { entry.completedAt = now }
            if entry.episode > old.episode { recordWatch(entryID: entry.id, episodes: entry.episode - old.episode, at: now) }
            entries[i] = entry
        } else {
            if entry.status == .completed, entry.completedAt == nil { entry.completedAt = now }
            entries.append(entry)
        }
    }
}
