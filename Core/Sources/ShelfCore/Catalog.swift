import Foundation

/// A title from the catalogue that may not be in the collection yet (similar titles, the «Обзор» tab).
public struct CatalogItem: Codable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String
    public var kind: String
    public var episodes: Int?
    public var episodesAired: Int?
    public var status: String
    public var score: Double?
    public var airedOn: String?
    public var posterURL: String
    public init(id: Int, title: String, originalTitle: String, kind: String, episodes: Int?, episodesAired: Int?, status: String, score: Double?, airedOn: String?, posterURL: String) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.kind = kind; self.episodes = episodes; self.episodesAired = episodesAired
        self.status = status; self.score = score; self.airedOn = airedOn; self.posterURL = posterURL
    }
    /// «ONA · 2024 · 16 серий · ★ 7.6»
    public var line: String {
        var parts = [Catalog.kindName(kind)]
        if let year = airedOn?.prefix(4) { parts.append(String(year)) }
        if status == Airing.ongoing { parts.append("выходит" + (episodesAired.map { " · \($0) из \(episodes.map(String.init) ?? "?")" } ?? "")) }
        else if status == Airing.anons { parts.append("анонс") }
        else if let e = episodes { parts.append("\(e) \(Airing.countWord(e))") }
        if let score, score > 0 { parts.append("★ " + String(format: "%.1f", score)) }
        return parts.joined(separator: " · ")
    }
    public func entry(status: WatchStatus, now: Date = Date()) -> Entry {
        var e = Entry(title: title)
        e.originalTitle = originalTitle; e.status = status; e.sourceID = id; e.sourceURL = "https://shikimori.io/animes/\(id)"
        e.coverURL = posterURL; e.coverLookupDisabled = false; e.updatedAt = now
        if !originalTitle.isEmpty, originalTitle != title { e.aliases = [originalTitle] }
        if status == .watching { e.watchedAt = now }
        return e
    }
}

/// Everything the catalogue says about a title: plot, genres, studio, score and media.
public struct AnimeDetails: Codable, Equatable {
    public struct Video: Codable, Equatable, Identifiable {
        public var url: String
        public var name: String
        public var kind: String
        public var id: String { url }
        /// «Трейлер PV2», «Опенинг», «Превью серии 4».
        public var title: String {
            switch kind {
            case "pv", "cm": return "Трейлер" + (name.isEmpty ? "" : " " + name)
            case "op": return "Опенинг" + (name.isEmpty ? "" : " · " + name)
            case "ed": return "Эндинг" + (name.isEmpty ? "" : " · " + name)
            case "episode_preview": return "Превью серии" + (name.isEmpty ? "" : " " + name)
            default: return name.isEmpty ? "Видео" : name
            }
        }
    }
    public var id: Int
    public var description: String
    public var genres: [String]
    public var studios: [String]
    public var score: Double?
    public var rating: String?
    public var duration: Int?
    public var videos: [Video]
    /// Small screenshot images; `screenshotsFull` holds the large ones in the same order.
    public var screenshots: [String]
    public var screenshotsFull: [String]
    public var checkedAt: Date

    /// «12+», «16+»…
    public var ratingLabel: String? {
        switch rating {
        case "g": return "0+"
        case "pg": return "6+"
        case "pg_13": return "12+"
        case "r": return "16+"
        case "r_plus": return "18+"
        case "rx": return "18+"
        default: return nil
        }
    }
}

public enum Catalog {
    static let fields = "id name russian kind episodes episodesAired status score airedOn { date } poster { mainUrl }"

    public enum Shelf: String, CaseIterable, Identifiable {
        case donghua = "Дунхуа: выходят сейчас", ongoing = "Онгоинги сезона", anons = "Анонсы", top = "Лучшие за всё время"
        public var id: String { rawValue }
        var filter: String {
            switch self {
            case .ongoing: return "status: \"ongoing\", order: popularity"
            case .donghua: return "kind: \"ona\", status: \"ongoing\", order: popularity"
            case .anons: return "status: \"anons\", order: popularity"
            case .top: return "order: ranked"
            }
        }
    }

    public static func kindName(_ kind: String) -> String {
        switch kind {
        case "tv": return "Сериал"
        case "ona": return "ONA"
        case "movie": return "Фильм"
        case "ova": return "OVA"
        case "special", "tv_special": return "Спецвыпуск"
        default: return kind.uppercased()
        }
    }

    private static func body(_ query: String, _ variables: [String: Any] = [:]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])) ?? Data()
    }

    public static func shelfQuery(_ shelf: Shelf, limit: Int = 24) -> Data {
        body("{ animes(\(shelf.filter), limit: \(limit), censored: true) { \(fields) } }")
    }
    public static func searchQuery(_ text: String) -> Data {
        body("query($q: String!) { animes(search: $q, limit: 30, censored: true) { \(fields) } }", ["q": text])
    }
    public static func detailsQuery(_ id: Int) -> Data {
        body("query($id: String!) { animes(ids: $id, limit: 1) { id score rating duration description genres { russian } studios { name } videos { url name kind } screenshots { originalUrl x332Url } } }", ["id": String(id)])
    }

    private static func list(_ data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["data"] as? [String: Any])?["animes"] as? [[String: Any]] else { throw ShelfError.invalid("Каталог вернул неожиданный ответ.") }
        return list
    }
    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
    private static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0) } }

    public static func parseItems(_ data: Data) throws -> [CatalogItem] {
        try list(data).compactMap { a in
            guard let id = int(a["id"]), let kind = a["kind"] as? String, kind != "music", kind != "pv", kind != "cm" else { return nil }
            let name = (a["name"] as? String) ?? ""
            let russian = (a["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let poster = ((a["poster"] as? [String: Any])?["mainUrl"] as? String) ?? ""
            return CatalogItem(id: id, title: String((russian ?? name).prefix(500)), originalTitle: String(name.prefix(500)), kind: kind,
                               episodes: int(a["episodes"]).flatMap { $0 > 0 ? $0 : nil }, episodesAired: int(a["episodesAired"]).flatMap { $0 > 0 ? $0 : nil },
                               status: (a["status"] as? String) ?? Airing.released, score: double(a["score"]).flatMap { $0 > 0 ? $0 : nil },
                               airedOn: ((a["airedOn"] as? [String: Any])?["date"] as? String).flatMap { $0.count == 10 ? $0 : nil },
                               posterURL: poster.hasPrefix("https://") ? poster : "")
        }
    }

    /// Shikimori's legacy «similar» list (REST); image paths are relative to the site.
    public static func parseSimilar(_ data: Data) throws -> [CatalogItem] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ShelfError.invalid("Каталог вернул неожиданный ответ.") }
        return list.prefix(20).compactMap { a in
            guard let id = int(a["id"]) else { return nil }
            let name = (a["name"] as? String) ?? ""
            let russian = (a["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let path = ((a["image"] as? [String: Any])?["original"] as? String) ?? ""
            let poster = path.hasPrefix("/") ? "https://shikimori.io" + path : path
            return CatalogItem(id: id, title: russian ?? name, originalTitle: name, kind: (a["kind"] as? String) ?? "tv",
                               episodes: int(a["episodes"]).flatMap { $0 > 0 ? $0 : nil }, episodesAired: int(a["episodes_aired"]).flatMap { $0 > 0 ? $0 : nil },
                               status: (a["status"] as? String) ?? Airing.released, score: double(a["score"]).flatMap { $0 > 0 ? $0 : nil },
                               airedOn: (a["aired_on"] as? String).flatMap { $0.count == 10 ? $0 : nil },
                               posterURL: CoverImagePolicy.isPlaceholder(poster) ? "" : poster)
        }
    }

    public static func parseDetails(_ data: Data, now: Date = Date()) throws -> AnimeDetails? {
        guard let a = try list(data).first, let id = int(a["id"]) else { return nil }
        let videos = ((a["videos"] as? [[String: Any]]) ?? []).compactMap { v -> AnimeDetails.Video? in
            guard let url = v["url"] as? String, url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return AnimeDetails.Video(url: url, name: (v["name"] as? String) ?? "", kind: (v["kind"] as? String) ?? "")
        }
        // Trailers and openings first, episode previews after them.
        let order = ["pv": 0, "cm": 0, "op": 1, "ed": 2]
        let sortedVideos = videos.enumerated().sorted { (order[$0.element.kind] ?? 3, $0.offset) < (order[$1.element.kind] ?? 3, $1.offset) }.map(\.element)
        let shots = ((a["screenshots"] as? [[String: Any]]) ?? []).prefix(20)
        return AnimeDetails(id: id, description: plainText((a["description"] as? String) ?? ""),
                            genres: ((a["genres"] as? [[String: Any]]) ?? []).compactMap { $0["russian"] as? String },
                            studios: ((a["studios"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String },
                            score: double(a["score"]).flatMap { $0 > 0 ? $0 : nil }, rating: a["rating"] as? String,
                            duration: int(a["duration"]).flatMap { $0 > 0 ? $0 : nil }, videos: Array(sortedVideos.prefix(12)),
                            screenshots: shots.compactMap { $0["x332Url"] as? String }, screenshotsFull: shots.compactMap { $0["originalUrl"] as? String },
                            checkedAt: now)
    }

    /// Shikimori descriptions contain BBCode links to characters: «[character=1]Химмель[/character]» → «Химмель».
    public static func plainText(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"\[/?[a-z_]+(=[^\]]*)?\]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
