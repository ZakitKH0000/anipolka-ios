import Foundation

/// AniLibria's own dub schedule for a title: the last dubbed episode and the next one.
public struct LibriaInfo: Codable, Equatable {
    public var alias: String
    public var publishedEpisode: Int?
    public var nextEpisode: Int?
    /// Calendar weekday as everywhere in the app: 1 = Sunday … 7 = Saturday.
    public var weekday: Int?
    public var url: String { "https://anilibria.top/anime/releases/release/\(alias)/episodes" }
}

/// AniList: exact time and number of the next episode (Shikimori ids are MyAnimeList ids).
public enum AniList {
    public static func query(_ malIDs: [Int]) -> Data {
        let q = "query($ids: [Int]) { Page(perPage: 50) { media(idMal_in: $ids, type: ANIME) { idMal nextAiringEpisode { episode airingAt } } } }"
        return (try? JSONSerialization.data(withJSONObject: ["query": q, "variables": ["ids": Array(malIDs.prefix(50))]])) ?? Data()
    }
    public struct Next: Equatable { public var episode: Int; public var at: Date }
    public static func parse(_ data: Data) throws -> [Int: Next] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = ((root["data"] as? [String: Any])?["Page"] as? [String: Any])?["media"] as? [[String: Any]] else { throw ShelfError.invalid("AniList вернул неожиданный ответ.") }
        var result: [Int: Next] = [:]
        for m in media {
            guard let id = (m["idMal"] as? NSNumber)?.intValue, let next = m["nextAiringEpisode"] as? [String: Any],
                  let episode = (next["episode"] as? NSNumber)?.intValue, let at = (next["airingAt"] as? NSNumber)?.doubleValue else { continue }
            result[id] = Next(episode: episode, at: Date(timeIntervalSince1970: at))
        }
        return result
    }
}

public enum AniLibria {
    public static let scheduleURL = URL(string: "https://anilibria.top/api/v1/anime/schedule/week")!

    /// Shikimori id → AniLibria dub schedule.
    public static func parseSchedule(_ data: Data) throws -> [Int: LibriaInfo] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ShelfError.invalid("AniLibria вернула неожиданный ответ.") }
        var result: [Int: LibriaInfo] = [:]
        for item in list {
            guard let release = item["release"] as? [String: Any], let alias = release["alias"] as? String, !alias.isEmpty, alias.count <= 200,
                  let shikimori = ((release["shikimori"] as? [String: Any])?["id"] as? NSNumber)?.intValue else { continue }
            // AniLibria counts Monday = 1 … Sunday = 7.
            let day = ((release["publish_day"] as? [String: Any])?["value"] as? NSNumber)?.intValue
            result[shikimori] = LibriaInfo(alias: alias,
                                           publishedEpisode: ((item["published_release_episode"] as? [String: Any])?["ordinal"] as? NSNumber)?.intValue,
                                           nextEpisode: (item["next_release_episode_number"] as? NSNumber)?.intValue,
                                           weekday: day.flatMap { (1...7).contains($0) ? $0 % 7 + 1 : nil })
        }
        return result
    }

    /// Dubbed episodes the user has not watched yet.
    public static func ahead(_ e: Entry) -> Int? {
        guard let published = e.airing?.libria?.publishedEpisode, e.status == .watching || e.status == .planned else { return nil }
        let n = published - e.seasonEpisode
        return (1...200).contains(n) ? n : nil
    }
}

/// A title from someone's public list on Shikimori or MyAnimeList.
public struct ListImportItem: Identifiable, Equatable {
    public var id: Int
    public var title: String
    public var originalTitle: String
    public var episode: Int
    public var status: WatchStatus
    public var posterURL: String
    public var included = true
    public var existing: String?
    public func entry(now: Date = Date()) -> Entry {
        var e = Entry(title: title, episode: episode)
        e.originalTitle = originalTitle; e.status = status; e.sourceID = id; e.sourceURL = "https://shikimori.io/animes/\(id)"
        e.coverURL = posterURL; e.coverLookupDisabled = false; e.updatedAt = now
        if !originalTitle.isEmpty, originalTitle != title { e.aliases = [originalTitle] }
        if status == .completed { e.completedAt = now }
        return e
    }
}

public enum ListImport {
    public enum Site: String, CaseIterable, Identifiable { case shikimori = "Shikimori", mal = "MyAnimeList"; public var id: String { rawValue } }

    public static func shikimoriURL(_ nickname: String) -> URL? {
        guard let nick = nickname.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !nick.isEmpty, !nick.contains("/") else { return nil }
        return URL(string: "https://shikimori.io/api/users/\(nick)/anime_rates?limit=5000")
    }
    public static func malURL(_ nickname: String, offset: Int) -> URL? {
        guard let nick = nickname.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !nick.isEmpty, !nick.contains("/") else { return nil }
        return URL(string: "https://myanimelist.net/animelist/\(nick)/load.json?offset=\(offset)&status=7")
    }

    static func status(shikimori: String) -> WatchStatus {
        switch shikimori {
        case "watching", "rewatching": return .watching
        case "completed": return .completed
        case "dropped": return .dropped
        default: return .planned
        }
    }
    static func status(mal: Int) -> WatchStatus {
        switch mal { case 1: return .watching; case 2: return .completed; case 4: return .dropped; default: return .planned }
    }

    public static func parseShikimori(_ data: Data) throws -> [ListImportItem] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ShelfError.invalid("Список не найден. Проверьте ник и что список открыт.") }
        return list.compactMap { r in
            guard let anime = r["anime"] as? [String: Any], let id = (anime["id"] as? NSNumber)?.intValue else { return nil }
            let name = (anime["name"] as? String) ?? ""
            let russian = (anime["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let path = ((anime["image"] as? [String: Any])?["original"] as? String) ?? ""
            let poster = path.hasPrefix("/") ? "https://shikimori.io" + path : path
            return ListImportItem(id: id, title: String((russian ?? name).prefix(500)), originalTitle: String(name.prefix(500)),
                                  episode: min(max(0, (r["episodes"] as? NSNumber)?.intValue ?? 0), 1_000_000),
                                  status: status(shikimori: (r["status"] as? String) ?? ""), posterURL: CoverImagePolicy.isPlaceholder(poster) ? "" : poster)
        }
    }

    public static func parseMAL(_ data: Data) throws -> [ListImportItem] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ShelfError.invalid("Список не найден. Проверьте ник и что список открыт.") }
        return list.compactMap { r in
            guard let id = (r["anime_id"] as? NSNumber)?.intValue else { return nil }
            let title = (r["anime_title"] as? String).map { String(describing: $0) } ?? String(id)
            let image = (r["anime_image_path"] as? String) ?? ""
            return ListImportItem(id: id, title: String(title.prefix(500)), originalTitle: String(title.prefix(500)),
                                  episode: min(max(0, (r["num_watched_episodes"] as? NSNumber)?.intValue ?? 0), 1_000_000),
                                  status: status(mal: (r["status"] as? NSNumber)?.intValue ?? 6), posterURL: image.hasPrefix("https://") ? image : "")
        }
    }

    /// Marks titles already in the collection (same catalogue id or the same name) and leaves them unchecked.
    public static func mark(_ items: [ListImportItem], in snapshot: Snapshot) -> [ListImportItem] {
        items.map { item in
            var x = item
            if let found = snapshot.entries.first(where: { $0.sourceID == item.id }) ?? TitleMatcher.existing(item.title, in: snapshot.entries) ?? TitleMatcher.existing(item.originalTitle, in: snapshot.entries) {
                x.existing = found.title; x.included = false
            }
            return x
        }
    }
}

public extension Airing {
    /// AniList knows the exact next episode where Shikimori has no time.
    static func merge(_ info: AiringInfo, aniList next: AniList.Next?, libria: LibriaInfo?, now: Date = Date()) -> AiringInfo {
        var result = info
        if let next, next.at > now.addingTimeInterval(-3600) {
            if result.nextEpisodeAt == nil || abs(result.nextEpisodeAt!.timeIntervalSince(next.at)) > 600 { result.nextEpisodeAt = next.at }
            result.nextEpisode = next.episode
        }
        result.libria = libria
        return result
    }
}
