import Foundation

/// One part of a franchise in the catalogue: a season, film, special or remaster.
public struct FranchisePart: Codable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String
    /// Shikimori kind: tv, ona, movie, ova, special, tv_special, music…
    public var kind: String
    public var episodes: Int?
    public var status: String
    public var airedOn: String?
    public var coverURL: String
    public init(id: Int, title: String, originalTitle: String, kind: String, episodes: Int?, status: String, airedOn: String?, coverURL: String) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.kind = kind; self.episodes = episodes; self.status = status; self.airedOn = airedOn; self.coverURL = coverURL
    }
}

/// All parts of a franchise in broadcast order, plus how the user counts episodes in it.
public struct FranchiseInfo: Codable, Equatable, Identifiable {
    public var key: String
    public var parts: [FranchisePart]
    public var checkedAt: Date
    /// Episodes are counted through all seasons (e.g. 200) instead of from 1 in every season.
    public var absolute: Bool?
    public var id: String { key }
    public init(key: String, parts: [FranchisePart], checkedAt: Date, absolute: Bool? = nil) {
        self.key = key; self.parts = parts; self.checkedAt = checkedAt; self.absolute = absolute
    }
}

public extension Entry {
    /// Episode number inside the current season; equals `episode` unless the franchise counts through seasons.
    var seasonEpisode: Int { max(0, episode - (episodeOffset ?? 0)) }
}

/// What to show for the next season: start it, or plan how to catch up before it airs.
public struct CatchUpPlan: Equatable {
    public var target: String
    public var days: Int
    public var remaining: Int
    public var perDay: Int
}

public enum Franchise {
    static let mainKinds: Set<String> = ["tv", "ona"]
    static let sideWords = ["ремастер", "спецвыпуск", "пролог", "recap", "remaster", "special", "рекап", "фильм", "movie", "pv"]

    /// GraphQL request body: every part of one franchise.
    public static func query(_ key: String) -> Data {
        let q = "query($f: String!) { animes(franchise: $f, limit: 50, order: aired_on) { id name russian kind episodes status airedOn { date } poster { mainUrl } } }"
        let body: [String: Any] = ["query": q, "variables": ["f": key]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    public static func parse(_ data: Data, key: String, now: Date = Date(), previous: FranchiseInfo? = nil) throws -> FranchiseInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["data"] as? [String: Any])?["animes"] as? [[String: Any]] else { throw ShelfError.invalid("Каталог вернул неожиданный ответ.") }
        let parts = list.compactMap { a -> FranchisePart? in
            guard let id = (a["id"] as? String).flatMap({ Int($0) }) ?? (a["id"] as? NSNumber)?.intValue,
                  let kind = a["kind"] as? String, kind != "music", kind != "pv", kind != "cm" else { return nil }
            let name = (a["name"] as? String) ?? ""
            let russian = (a["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let episodes = (a["episodes"] as? NSNumber)?.intValue
            let poster = ((a["poster"] as? [String: Any])?["mainUrl"] as? String) ?? ""
            return FranchisePart(id: id, title: String((russian ?? name).prefix(500)), originalTitle: String(name.prefix(500)), kind: kind,
                                 episodes: (episodes ?? 0) > 0 ? episodes : nil, status: (a["status"] as? String) ?? Airing.released,
                                 airedOn: ((a["airedOn"] as? [String: Any])?["date"] as? String).flatMap { $0.count == 10 ? $0 : nil },
                                 coverURL: poster.hasPrefix("https://") ? poster : "")
        }.sorted { ($0.airedOn ?? "9999") < ($1.airedOn ?? "9999") }
        return FranchiseInfo(key: key, parts: Array(parts.prefix(50)), checkedAt: now, absolute: previous?.absolute)
    }

    public static func needsRefresh(_ info: FranchiseInfo?, now: Date = Date()) -> Bool {
        guard let info else { return true }
        let ongoing = info.parts.contains { $0.status != Airing.released }
        return now.timeIntervalSince(info.checkedAt) > (ongoing ? 2 : 7) * 86400
    }

    /// A season of the main story (not a film, special, prologue or remaster).
    public static func isMain(_ part: FranchisePart) -> Bool {
        guard mainKinds.contains(part.kind), (part.episodes ?? 12) >= 6 else { return false }
        let name = (part.title + " " + part.originalTitle).lowercased()
        return !sideWords.contains { name.contains($0) }
    }

    public static func info(_ entry: Entry, in snapshot: Snapshot) -> FranchiseInfo? {
        guard let key = entry.franchise, let info = snapshot.franchises?.first(where: { $0.key == key }), info.parts.count > 1 else { return nil }
        return info
    }

    public static func members(_ entry: Entry, in snapshot: Snapshot) -> [Entry] {
        guard let key = entry.franchise else { return [entry] }
        return snapshot.entries.filter { $0.franchise == key }
    }

    /// The season shown for the whole franchise: the one being watched most recently, else the latest touched.
    public static func current(_ members: [Entry]) -> Entry? {
        let watching = members.filter { $0.status == .watching }
        let pool = watching.isEmpty ? members : watching
        return pool.max { ($0.watchedAt ?? $0.updatedAt) < ($1.watchedAt ?? $1.updatedAt) }
    }

    /// One card per franchise: keeps the current season of each franchise with two or more entries, in list order.
    public static func grouped(_ entries: [Entry], in snapshot: Snapshot) -> [Entry] {
        var shown = Set<String>()
        var currentByKey: [String: UUID] = [:]
        for key in Set(snapshot.entries.compactMap(\.franchise)) {
            let members = snapshot.entries.filter { $0.franchise == key }
            if members.count > 1, let c = current(members) { currentByKey[key] = c.id }
        }
        var result: [Entry] = []
        for e in entries {
            guard let key = e.franchise, let currentID = currentByKey[key] else { result.append(e); continue }
            guard !shown.contains(key) else { continue }
            shown.insert(key)
            result.append(entries.first { $0.id == currentID } ?? snapshot.entries.first { $0.id == currentID } ?? e)
        }
        return result
    }

    public static func part(_ entry: Entry, in info: FranchiseInfo) -> FranchisePart? {
        entry.sourceID.flatMap { id in info.parts.first { $0.id == id } }
    }

    /// «Сезон 2», «Фильм», «Спецвыпуск», «Ремастер».
    public static func label(_ part: FranchisePart, in info: FranchiseInfo) -> String {
        if isMain(part), let index = info.parts.filter(isMain).firstIndex(of: part) { return "Сезон \(index + 1)" }
        let name = (part.title + " " + part.originalTitle).lowercased()
        if part.kind == "movie" { return "Фильм" }
        if name.contains("ремастер") || name.contains("remaster") { return "Ремастер" }
        if name.contains("пролог") { return "Пролог" }
        return "Спецвыпуск"
    }

    /// Episodes of the main seasons before this part: the start of its numbering when counting through seasons.
    public static func suggestedOffset(_ part: FranchisePart, in info: FranchiseInfo) -> Int {
        guard let index = info.parts.firstIndex(of: part) else { return 0 }
        return info.parts[..<index].filter(isMain).reduce(0) { $0 + ($1.episodes ?? 0) }
    }

    /// The next main season after this entry's part.
    public static func nextPart(_ entry: Entry, in info: FranchiseInfo) -> FranchisePart? {
        guard let current = part(entry, in: info), let index = info.parts.firstIndex(of: current) else { return nil }
        return info.parts[(index + 1)...].first(where: isMain)
    }

    /// True when every episode of the season has been watched and the season has finished airing.
    public static func seasonFinished(_ entry: Entry, in info: FranchiseInfo) -> Bool {
        guard let part = Franchise.part(entry, in: info), part.status == Airing.released, let total = part.episodes else { return false }
        return entry.seasonEpisode >= total
    }

    /// «Сезон досмотрен — начать следующий?» unless the next season is already being watched or was dismissed.
    public static func nextSeasonPrompt(_ entry: Entry, in snapshot: Snapshot) -> FranchisePart? {
        guard let info = Franchise.info(entry, in: snapshot), seasonFinished(entry, in: info), let next = nextPart(entry, in: info),
              next.status != Airing.anons, entry.dismissedSequelID != next.id else { return nil }
        if let existing = snapshot.entries.first(where: { $0.sourceID == next.id }), existing.status == .watching || existing.status == .completed || existing.episode > 0 { return nil }
        return next
    }

    /// The main season the user's own «Сезон N» points to, when the entry is bound to another part.
    public static func seasonMismatch(_ entry: Entry, in snapshot: Snapshot) -> FranchisePart? {
        guard let season = entry.season, let info = Franchise.info(entry, in: snapshot) else { return nil }
        let main = info.parts.filter(isMain)
        guard main.indices.contains(season - 1) else { return nil }
        let wanted = main[season - 1]
        guard wanted.id != entry.sourceID, !snapshot.entries.contains(where: { $0.id != entry.id && $0.sourceID == wanted.id }) else { return nil }
        return wanted
    }

    /// Binds the entry to another part: catalogue id, page, poster and broadcast data follow; title and progress stay.
    public static func rebind(_ snapshot: inout Snapshot, entryID: UUID, to part: FranchisePart, now: Date = Date()) {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == entryID }) else { return }
        snapshot.entries[i].sourceID = part.id
        snapshot.entries[i].sourceURL = "https://shikimori.io/animes/\(part.id)"
        snapshot.entries[i].originalTitle = part.originalTitle
        if !part.coverURL.isEmpty { snapshot.entries[i].coverURL = part.coverURL; snapshot.entries[i].coverData = nil; snapshot.entries[i].coverDiscovery = nil }
        snapshot.entries[i].airing = nil
        snapshot.entries[i].updatedAt = now
        var names = snapshot.entries[i].aliases ?? []
        if !part.title.isEmpty, part.title != snapshot.entries[i].title, !names.contains(part.title) { names.append(part.title) }
        snapshot.entries[i].aliases = names.isEmpty ? nil : Array(names.prefix(Aliases.limit))
    }

    /// A new entry for a part, numbered like the rest of the franchise.
    public static func entry(for part: FranchisePart, after previous: Entry?, in info: FranchiseInfo, status: WatchStatus, now: Date = Date()) -> Entry {
        var e = Entry(title: part.title)
        e.originalTitle = part.originalTitle; e.status = status; e.sourceID = part.id; e.franchise = info.key
        e.sourceURL = "https://shikimori.io/animes/\(part.id)"; e.coverURL = part.coverURL; e.coverLookupDisabled = false; e.updatedAt = now
        if !part.originalTitle.isEmpty, part.originalTitle != part.title { e.aliases = [part.originalTitle] }
        if let previous { e.relatedIDs = [previous.id]; e.favorite = previous.favorite; e.tags = previous.tags }
        if info.absolute == true {
            let offset = suggestedOffset(part, in: info)
            e.episodeOffset = offset; e.episode = offset
        }
        if status == .watching { e.watchedAt = now }
        return e
    }

    /// Finishes the current season and starts the next one (existing entry or a new one). Returns the next entry's id.
    @discardableResult
    public static func startNext(_ snapshot: inout Snapshot, from entryID: UUID, next part: FranchisePart, now: Date = Date()) -> UUID? {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == entryID }), let info = Franchise.info(snapshot.entries[i], in: snapshot) else { return nil }
        snapshot.entries[i].status = .completed
        if snapshot.entries[i].completedAt == nil { snapshot.entries[i].completedAt = now }
        snapshot.entries[i].updatedAt = now
        if let j = snapshot.entries.firstIndex(where: { $0.sourceID == part.id }) {
            snapshot.entries[j].status = .watching; snapshot.entries[j].watchedAt = now; snapshot.entries[j].updatedAt = now
            if snapshot.entries[j].franchise == nil { snapshot.entries[j].franchise = info.key }
            return snapshot.entries[j].id
        }
        let created = entry(for: part, after: snapshot.entries[i], in: info, status: .watching, now: now)
        snapshot.entries.insert(created, at: 0)
        return created.id
    }

    /// Switches the franchise between counting from 1 in every season and counting through seasons.
    public static func setAbsolute(_ snapshot: inout Snapshot, key: String, absolute: Bool) {
        guard let f = snapshot.franchises?.firstIndex(where: { $0.key == key }) else { return }
        let info = snapshot.franchises![f]
        for i in snapshot.entries.indices where snapshot.entries[i].franchise == key {
            let seasonEpisode = snapshot.entries[i].seasonEpisode
            if absolute, let part = Franchise.part(snapshot.entries[i], in: info) {
                let offset = suggestedOffset(part, in: info)
                let alreadyThrough = snapshot.entries[i].episodeOffset == nil && countsThroughSeasons(snapshot.entries[i], part: part)
                snapshot.entries[i].episodeOffset = offset
                if !alreadyThrough { snapshot.entries[i].episode = min(1_000_000, offset + seasonEpisode) }
            } else {
                snapshot.entries[i].episode = seasonEpisode
                snapshot.entries[i].episodeOffset = nil
            }
        }
        snapshot.franchises![f].absolute = absolute ? true : nil
    }

    /// The number is larger than the whole season: the user already counts through all seasons.
    public static func countsThroughSeasons(_ entry: Entry, part: FranchisePart) -> Bool {
        guard entry.episodeOffset == nil, let total = part.episodes else { return false }
        return entry.episode > total
    }

    /// The user corrects where this season starts in through-season numbering (episodes before it).
    public static func setOffset(_ snapshot: inout Snapshot, entryID: UUID, offset: Int) {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == entryID }) else { return }
        let seasonEpisode = snapshot.entries[i].seasonEpisode
        let value = min(max(0, offset), 1_000_000)
        snapshot.entries[i].episodeOffset = value
        snapshot.entries[i].episode = min(1_000_000, value + seasonEpisode)
    }

    /// How many episodes a day to finish before the next part (or announced continuation) premieres.
    public static func catchUp(_ entry: Entry, in snapshot: Snapshot, now: Date = Date(), calendar: Calendar = .current) -> CatchUpPlan? {
        guard entry.status == .watching || entry.status == .planned else { return nil }
        let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX"); parse.calendar = calendar; parse.timeZone = calendar.timeZone; parse.dateFormat = "yyyy-MM-dd"
        var targetTitle: String?, targetDate: Date?, remaining = 0
        if let info = Franchise.info(entry, in: snapshot), let current = part(entry, in: info), let index = info.parts.firstIndex(of: current) {
            remaining = max(0, (current.episodes ?? entry.seasonEpisode) - entry.seasonEpisode)
            // The first part premiering in the future is the goal (a season or a film); main seasons before it add up.
            for p in info.parts[(index + 1)...] {
                if let day = p.airedOn.flatMap(parse.date(from:)), day > now { targetTitle = p.title; targetDate = day; break }
                guard isMain(p), !snapshot.entries.contains(where: { $0.sourceID == p.id && $0.status == .completed }) else { continue }
                remaining += p.episodes ?? 0
            }
        } else if let hint = entry.airing?.sequel, let day = hint.airedOn.flatMap(parse.date(from:)), day > now,
                  let total = entry.airing?.episodes ?? entry.airing?.episodesAired {
            targetTitle = hint.title; targetDate = day; remaining = max(0, total - entry.seasonEpisode)
        }
        guard let target = targetTitle, let date = targetDate, remaining > 0 else { return nil }
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 1)
        return CatchUpPlan(target: target, days: days, remaining: remaining, perDay: Int((Double(remaining) / Double(days)).rounded(.up)))
    }
}
