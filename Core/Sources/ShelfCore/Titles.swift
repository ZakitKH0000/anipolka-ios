import Foundation

/// Other names of a work: Russian, English, original, Chinese and the user's own variants.
public enum Aliases {
    public static let limit = 30
    public static let maxLength = 200
    /// One name per line; names may contain commas, so only line breaks separate them.
    public static func parse(_ text: String) -> [String] {
        merge(nil, adding: text.components(separatedBy: .newlines), except: [])
    }
    /// Adds new names, skipping duplicates and names equal to `except` (usually the entry's own title).
    public static func merge(_ current: [String]?, adding names: [String], except: [String]) -> [String] {
        var result: [String] = []
        var seen = Set(except.map(TitleMatcher.key).filter { !$0.isEmpty })
        for name in (current ?? []) + names {
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            let key = TitleMatcher.key(clean)
            guard !key.isEmpty, result.count < limit, seen.insert(key).inserted else { continue }
            result.append(clean)
        }
        return result
    }
}

public enum TitleMatcher {
    /// Comparison key: case, accents, punctuation, stars and spaces are ignored,
    /// so «Tun Shi Xing Kong» and «Tunshi Xingkong» are the same name.
    public static func key(_ name: String) -> String {
        TitleIdentity.normalized(TitleIdentity.query(name)).replacingOccurrences(of: " ", with: "")
    }
    public static func names(_ entry: Entry) -> [String] {
        ([entry.title, entry.originalTitle] + (entry.aliases ?? [])).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func keys(_ names: [String]) -> Set<String> { Set(names.map(key).filter { $0.count >= 3 }) }
    /// An existing entry known under exactly this name (any of its names).
    public static func existing(_ title: String, in entries: [Entry]) -> Entry? {
        let wanted = key(title)
        guard wanted.count >= 3 else { return nil }
        return entries.first { keys(names($0)).contains(wanted) }
    }
    /// True when a source page names the same work. Season pages usually extend the base
    /// name («Tunshi Xingkong 4th season»), so a long name contained in another also counts.
    public static func matches(_ pageNames: [String], _ entry: Entry) -> Bool {
        let own = keys(names(entry)), other = keys(pageNames)
        if !own.isDisjoint(with: other) { return true }
        return own.contains { a in other.contains { b in min(a.count, b.count) >= 6 && (a.contains(b) || b.contains(a)) } }
    }
}

/// Finds AniVibe title pages through the site's public sitemap, without its search.
public enum AnivibeCatalog {
    public static let sitemapIndex = URL(string: "https://anivibe.pro/sitemap.xml")!
    public struct Page: Equatable, Identifiable {
        public let id: Int
        public let url: String
        /// Words of the page address, e.g. «tunshi xingkong 4th season».
        public let slugName: String
    }
    public static func locations(in xml: String) -> [String] {
        var result: [String] = []
        var rest = xml[...]
        while let start = rest.range(of: "<loc>"), let end = rest[start.upperBound...].range(of: "</loc>") {
            result.append(rest[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "&amp;", with: "&"))
            rest = rest[end.upperBound...]
        }
        return result
    }
    /// Only sitemap files of anivibe.pro itself are followed.
    public static func sitemapFiles(in xml: String) -> [URL] {
        Array(locations(in: xml).compactMap { loc -> URL? in
            guard let url = URL(string: loc), url.scheme == "https", url.host == "anivibe.pro", url.path.hasSuffix(".xml") else { return nil }
            return url
        }.prefix(20))
    }
    public static func pages(in locations: [String]) -> [Page] {
        locations.compactMap { loc in
            guard let url = AnivibePageParser.canonicalURL(loc), let last = url.path.split(separator: "/").last,
                  let dash = last.firstIndex(of: "-"), let id = Int(last[..<dash]) else { return nil }
            let slug = last[last.index(after: dash)...].replacingOccurrences(of: "-", with: " ")
            return Page(id: id, url: url.absoluteString, slugName: slug)
        }
    }
    /// Exact address matches first, then pages whose address extends a known name
    /// (other seasons, films). The user always makes the final choice.
    public static func candidates(for entry: Entry, in pages: [Page], limit: Int = 8) -> [Page] {
        let keys = TitleMatcher.keys(TitleMatcher.names(entry))
        var ranked: [(Int, Page)] = []
        var seen = Set<Int>()
        for page in pages where seen.insert(page.id).inserted {
            let slug = TitleMatcher.key(page.slugName)
            if keys.contains(slug) { ranked.append((0, page)) }
            else if keys.contains(where: { $0.count >= 6 && slug.hasPrefix($0) }) { ranked.append((1, page)) }
        }
        return Array(ranked.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.id < $1.1.id }.map(\.1).prefix(limit))
    }
}

public struct WeekBucket: Equatable {
    public let start: Date
    public let episodes: Int
}

public enum WatchHistory {
    public static func marks(for id: UUID, in snapshot: Snapshot) -> [WatchMark] {
        (snapshot.history ?? []).filter { $0.entryID == id }.sorted { $0.at > $1.at }
    }
    /// Episodes per week for the last `weeks` weeks, oldest first.
    public static func weekly(_ marks: [WatchMark], weeks: Int, now: Date = Date(), calendar: Calendar = .current) -> [WeekBucket] {
        guard weeks > 0, let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<weeks).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: current),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            return WeekBucket(start: start, episodes: marks.filter { $0.at >= start && $0.at < end }.reduce(0) { $0 + $1.episodes })
        }
    }
}

public enum ShelfExport {
    /// Same format as the text import: «Название 24», one title per line.
    public static func text(_ entries: [Entry]) -> String {
        entries.map { "\($0.title) \($0.episode)" }.joined(separator: "\n")
    }
}

public enum WatchSuggestion {
    /// Titles worth starting now: available new episodes or «На потом».
    public static func pool(_ entries: [Entry]) -> [Entry] {
        entries.filter { Backlog.available($0) != nil || $0.status == .planned }
    }
    public static func pick<G: RandomNumberGenerator>(_ entries: [Entry], excluding: UUID? = nil, using generator: inout G) -> Entry? {
        let candidates = Self.pool(entries)
        return candidates.filter { $0.id != excluding }.randomElement(using: &generator) ?? candidates.randomElement(using: &generator)
    }
}

extension Backlog {
    /// Watched up to the latest episode of an enabled source; waiting for the next one.
    public static func caughtUp(_ entry: Entry) -> Bool {
        entry.status == .watching && latest(entry) == entry.episode && entry.episode > 0
    }
}

extension Entry {
    /// Remembers other names of the same work without touching the user's own title.
    public mutating func learnNames(_ names: [String]) {
        let merged = Aliases.merge(aliases, adding: names, except: [title, originalTitle])
        aliases = merged.isEmpty ? nil : merged
    }
}
