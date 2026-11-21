import Foundation

/// Seasons of a title when Shikimori gives it no franchise: the chain of prequels and sequels.
public enum FranchiseChain {
    public static let prefix = "chain-"
    public static func isChain(_ key: String) -> Bool { key.hasPrefix(prefix) }

    public struct Node: Equatable {
        public var part: FranchisePart
        /// Prequels and sequels: the neighbours in the chain.
        public var neighbours: [Int]
    }

    public static func query(_ ids: [Int]) -> Data {
        let q = "query($ids: String!) { animes(ids: $ids, limit: 50) { id name russian kind episodes status airedOn { date } poster { mainUrl } related { relationKind anime { id } } } }"
        let body: [String: Any] = ["query": q, "variables": ["ids": ids.prefix(50).map(String.init).joined(separator: ",")]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    public static func parse(_ data: Data) throws -> [Node] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["data"] as? [String: Any])?["animes"] as? [[String: Any]] else { throw ShelfError.invalid("Каталог вернул неожиданный ответ.") }
        return list.compactMap { a in
            guard let id = (a["id"] as? String).flatMap({ Int($0) }) ?? (a["id"] as? NSNumber)?.intValue, let kind = a["kind"] as? String, !["music", "pv", "cm"].contains(kind) else { return nil }
            let name = (a["name"] as? String) ?? ""
            let russian = (a["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let episodes = (a["episodes"] as? NSNumber)?.intValue
            let poster = ((a["poster"] as? [String: Any])?["mainUrl"] as? String) ?? ""
            let part = FranchisePart(id: id, title: String((russian ?? name).prefix(500)), originalTitle: String(name.prefix(500)), kind: kind,
                                     episodes: (episodes ?? 0) > 0 ? episodes : nil, status: (a["status"] as? String) ?? Airing.released,
                                     airedOn: ((a["airedOn"] as? [String: Any])?["date"] as? String).flatMap { $0.count == 10 ? $0 : nil },
                                     coverURL: poster.hasPrefix("https://") ? poster : "")
            let neighbours = ((a["related"] as? [[String: Any]]) ?? []).compactMap { r -> Int? in
                guard let kind = r["relationKind"] as? String, kind == "prequel" || kind == "sequel", let anime = r["anime"] as? [String: Any] else { return nil }
                return (anime["id"] as? String).flatMap { Int($0) } ?? (anime["id"] as? NSNumber)?.intValue
            }
            return Node(part: part, neighbours: neighbours)
        }
    }

    /// Parts in broadcast order; the key is named after the earliest part, so every season finds the same key.
    public static func assemble(_ nodes: [Node], now: Date = Date(), previous: FranchiseInfo? = nil) -> FranchiseInfo? {
        let parts = nodes.map(\.part).sorted { ($0.airedOn ?? "9999") < ($1.airedOn ?? "9999") }
        guard let first = parts.first else { return nil }
        return FranchiseInfo(key: prefix + String(first.id), parts: Array(parts.prefix(50)), checkedAt: now, absolute: previous?.absolute)
    }
}

/// The user's number runs past the season the entry is bound to: «Серия 48» of a 26-episode season is season 2, episode 22.
public struct SeasonPosition: Equatable {
    public var part: FranchisePart
    public var season: Int
    public var episode: Int
    public var offset: Int
}

extension Franchise {
    /// Where the user's own number lands among the main seasons, counting from the first one.
    public static func position(_ entry: Entry, in info: FranchiseInfo) -> SeasonPosition? {
        let main = info.parts.filter(isMain)
        guard !main.isEmpty else { return nil }
        let number = entry.episode
        var before = 0
        for (index, part) in main.enumerated() {
            let total = part.episodes ?? (part.status == Airing.released ? 0 : Int.max / 4)
            if number <= before + total || index == main.count - 1 {
                return SeasonPosition(part: part, season: index + 1, episode: max(0, number - before), offset: before)
            }
            before += total
        }
        return nil
    }

    /// «Вы на 2 сезоне, серия 22»: the number counts through seasons but the entry is still bound to an earlier one.
    public static func overflow(_ entry: Entry, in snapshot: Snapshot) -> SeasonPosition? {
        guard (entry.episodeOffset ?? 0) == 0, let info = Franchise.info(entry, in: snapshot), let current = part(entry, in: info),
              isMain(current), let total = current.episodes, entry.episode > total,
              let position = position(entry, in: info), position.part.id != current.id, position.offset > 0,
              !snapshot.entries.contains(where: { $0.id != entry.id && $0.sourceID == position.part.id }) else { return nil }
        return position
    }

    /// Moves the entry to the season its number belongs to; the user's own number stays as through-season numbering.
    public static func move(_ snapshot: inout Snapshot, entryID: UUID, to position: SeasonPosition, now: Date = Date()) {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == entryID }), let key = snapshot.entries[i].franchise else { return }
        rebind(&snapshot, entryID: entryID, to: position.part, now: now)
        snapshot.entries[i].episodeOffset = position.offset
        snapshot.entries[i].season = position.season
        if snapshot.entries[i].status == .completed { snapshot.entries[i].status = .watching; snapshot.entries[i].completedAt = nil }
        if let f = snapshot.franchises?.firstIndex(where: { $0.key == key }) { snapshot.franchises![f].absolute = true }
    }

    /// The second line under the big number: «сезон 2 · серия 22» or just «сезон 2».
    public static func seasonLine(_ entry: Entry, in snapshot: Snapshot) -> String? {
        if let over = overflow(entry, in: snapshot) { return "сезон \(over.season) · серия \(over.episode)" }
        guard let info = Franchise.info(entry, in: snapshot), let current = part(entry, in: info), isMain(current),
              let index = info.parts.filter(isMain).firstIndex(of: current) else { return nil }
        return (entry.episodeOffset ?? 0) > 0 ? "сезон \(index + 1) · серия \(entry.seasonEpisode)" : "сезон \(index + 1)"
    }
}
