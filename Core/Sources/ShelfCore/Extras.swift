import Foundation

/// «Где остановился» and other notes tied to an episode.
public struct EpisodeNote: Codable, Equatable, Identifiable {
    public static let limit = 300
    public var id = UUID()
    public var episode: Int
    /// Position inside the episode, «14:30» or «1:02:03»; empty when not given.
    public var time: String
    public var text: String
    public var createdAt: Date
    public init(episode: Int, time: String = "", text: String = "", createdAt: Date = Date()) {
        self.episode = episode; self.time = time; self.text = text; self.createdAt = createdAt
    }
}

/// A place where the title is watched: a platform, a playlist, a specific dub.
public struct WatchLink: Codable, Equatable, Identifiable {
    public static let limit = 20
    public var id = UUID()
    public var label: String
    public var url: String
    public init(label: String, url: String) { self.label = label; self.url = url }
}

public enum EpisodeTime {
    /// Accepts «14:30», «14.30», «1:02:03»; returns «14:30» / «1:02:03», nil for anything else.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ":.")).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let values = parts.map { $0! }
        guard values.dropFirst().allSatisfy({ $0 < 60 }), values[0] < (values.count == 3 ? 24 : 600) else { return nil }
        return values.count == 2 ? String(format: "%ld:%02ld", values[0], values[1]) : String(format: "%ld:%02ld:%02ld", values[0], values[1], values[2])
    }
}

extension Entry {
    /// The latest note: where the user stopped last time.
    public var resumePoint: EpisodeNote? { (notes ?? []).max { $0.createdAt < $1.createdAt } }
    public mutating func addNote(_ note: EpisodeNote) {
        var all = notes ?? []
        all.append(note)
        if all.count > EpisodeNote.limit { all.removeFirst(all.count - EpisodeNote.limit) }
        notes = all
    }
    /// Starts watching again from the beginning; the first pass stays recorded.
    public mutating func startRewatch(now: Date = Date()) {
        firstRunEpisode = max(firstRunEpisode ?? 0, episode)
        rewatch = (rewatch ?? 0) + 1
        episode = 0; status = .watching; watchedAt = now; updatedAt = now
    }
    /// Makes a saved link the main «Открыть просмотр» link; the previous main link is kept in the list.
    public mutating func promoteLink(_ id: UUID) {
        guard var all = links, let i = all.firstIndex(where: { $0.id == id }) else { return }
        let chosen = all.remove(at: i)
        if !watchURL.isEmpty, !all.contains(where: { $0.url == watchURL }) { all.insert(WatchLink(label: "Прежняя основная", url: watchURL), at: 0) }
        watchURL = chosen.url
        links = all.isEmpty ? nil : all
    }
    public var passTitle: String? {
        guard let rewatch, rewatch > 0 else { return nil }
        return "Пересмотр №\(rewatch + 1)" + (firstRunEpisode.map { " · в прошлый раз: \($0)" } ?? "")
    }
}

public enum PremierePlanner {
    public static let reminderHour = 10
    public static func upcoming(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        let today = calendar.startOfDay(for: now)
        return entries.filter { e in
            guard let date = e.premiereDate, e.status == .planned || e.status == .watching else { return false }
            return calendar.startOfDay(for: date) >= today
        }.sorted { $0.premiereDate! < $1.premiereDate! }
    }
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Премьера сегодня"
        case 1: return "Премьера завтра"
        default:
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone; formatter.setLocalizedDateFormatFromTemplate("dMMM")
            return "Премьера \(formatter.string(from: date))"
        }
    }
}

public struct ShelfSection: Equatable, Identifiable {
    public let title: String
    public let entries: [Entry]
    public var id: String { title }
}

public enum ShelfSections {
    /// Horizontal shelves; every title appears once, in the first shelf that fits it.
    public static func make(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [ShelfSection] {
        var used = Set<UUID>()
        func take(_ title: String, _ list: [Entry]) -> ShelfSection? {
            let fresh = list.filter { used.insert($0.id).inserted }
            return fresh.isEmpty ? nil : ShelfSection(title: title, entries: fresh)
        }
        let behind = entries.filter { Backlog.available($0) != nil }
        return [
            take("Есть новые серии", behind),
            take("Смотрю", entries.filter { $0.status == .watching }),
            take("Скоро премьера", PremierePlanner.upcoming(entries, now: now, calendar: calendar)),
            take("На потом", entries.filter { $0.status == .planned }),
            take("Завершено", entries.filter { $0.status == .completed }),
            take("Заброшено", entries.filter { $0.status == .dropped })
        ].compactMap { $0 }
    }
}

/// Numbers for the shareable «АниПолка <год>» card.
public struct YearSummary: Equatable {
    public var year: Int
    public var episodes = 0
    public var activeDays = 0
    public var mostWatched: String?
    public var completed: [String] = []
    public var topRated: [String] = []
    public init(snapshot: Snapshot, year: Int, calendar: Calendar = .current) {
        self.year = year
        let marks = (snapshot.history ?? []).filter { calendar.component(.year, from: $0.at) == year }
        episodes = marks.reduce(0) { $0 + $1.episodes }
        activeDays = Set(marks.map { calendar.startOfDay(for: $0.at) }).count
        var perEntry: [UUID: Int] = [:]
        for mark in marks { perEntry[mark.entryID, default: 0] += mark.episodes }
        if let best = perEntry.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString > $1.key.uuidString }) {
            mostWatched = snapshot.entries.first { $0.id == best.key }?.title
        }
        completed = snapshot.entries.filter { $0.completedAt.map { calendar.component(.year, from: $0) == year } ?? false }.map(\.title)
        topRated = snapshot.entries.filter { $0.rating == 5 }.map(\.title)
    }
}

/// The user's favourite dubbing teams, matched against connected source labels.
public enum Dubs {
    public static let limit = 50
    /// «ПВА ШОУ · сезон 1 · Kodik» → «ПВА ШОУ».
    public static func name(fromLabel label: String) -> String {
        (label.components(separatedBy: " · ").first ?? label).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func isFavorite(_ name: String, in favorites: [String]) -> Bool { Tags.contains(favorites, name) }
    /// Favourite dubs first; the page order is kept otherwise.
    public static func sorted(_ options: [SourceOption], favorites: [String]) -> [SourceOption] {
        options.filter { isFavorite(name(fromLabel: $0.label), in: favorites) } + options.filter { !isFavorite(name(fromLabel: $0.label), in: favorites) }
    }
    public static func entryUses(_ entry: Entry, dub: String) -> Bool {
        (entry.subscriptions ?? []).contains { Tags.contains([name(fromLabel: $0.label)], dub) }
    }
    /// Favourite dubs that at least one title is connected to.
    public static func inUse(_ entries: [Entry], favorites: [String]) -> [String] {
        favorites.filter { dub in entries.contains { entryUses($0, dub: dub) } }
    }
    public static func toggled(_ name: String, in favorites: [String]) -> [String] {
        if isFavorite(name, in: favorites) { return favorites.filter { !Tags.contains([$0], name) } }
        return Array((favorites + [String(name.prefix(80))]).prefix(limit))
    }
}

public struct WeekDayPlan: Equatable, Identifiable {
    public let date: Date
    public let releases: [String]
    public let premieres: [String]
    public var id: Date { date }
}

public enum WeekPlan {
    /// Seven days starting today: titles from the user's release days and premieres on that date.
    public static func days(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [WeekDayPlan] {
        let today = calendar.startOfDay(for: now)
        let premieres = PremierePlanner.upcoming(entries, now: now, calendar: calendar)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            return WeekDayPlan(date: day, releases: ReleasePlanner.due(entries, weekday: weekday).map(\.title),
                               premieres: premieres.filter { calendar.isDate($0.premiereDate!, inSameDayAs: day) }.map(\.title))
        }
    }
}

public enum Relations {
    public static let limit = 30
    /// Links work both ways: a title shows parts it links to and parts that link to it.
    public static func related(of entry: Entry, in entries: [Entry]) -> [Entry] {
        let own = Set(entry.relatedIDs ?? [])
        return entries.filter { $0.id != entry.id && (own.contains($0.id) || ($0.relatedIDs ?? []).contains(entry.id)) }
    }
    /// Removes a link in both directions.
    public static func unlink(_ a: UUID, _ b: UUID, in snapshot: inout Snapshot) {
        for i in snapshot.entries.indices where snapshot.entries[i].id == a || snapshot.entries[i].id == b {
            let other = snapshot.entries[i].id == a ? b : a
            snapshot.entries[i].relatedIDs?.removeAll { $0 == other }
            if snapshot.entries[i].relatedIDs?.isEmpty == true { snapshot.entries[i].relatedIDs = nil }
        }
    }
}
