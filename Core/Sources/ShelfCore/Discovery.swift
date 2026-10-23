import Foundation

public enum TitleIdentity {
    public static func normalized(_ title: String) -> String {
        title.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"ru_RU"))
            .replacingOccurrences(of:"ё",with:"е")
            .components(separatedBy:CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator:" ")
    }
    /// Автоматически выбирается только единственное точное совпадение названия, без угадывания сезона.
    public static func uniqueExactMatch(query: String, candidates: [[String]]) -> Int? {
        let key = normalized(query)
        guard key.count >= 3 else { return nil }
        let matches = candidates.indices.filter { candidates[$0].contains { normalized($0) == key } }
        return matches.count == 1 ? matches[0] : nil
    }
    public static func query(_ title: String) -> String {
        title.replacingOccurrences(of:"⭐",with:"").replacingOccurrences(of:"★",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

public struct CoverDiscovery: Codable, Equatable {
    public var checkedAt: Date
    public var query: String
    public var message: String
    public var needsChoice: Bool
    public init(query: String, message: String, needsChoice: Bool, now: Date = Date()) { self.query = query; self.message = message; self.needsChoice = needsChoice; checkedAt = now }
}

public struct ReleaseSubscription: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var pageURL: String
    public var optionID: String
    public var label: String
    public var enabled = true
    public var lastEpisode: Int?
    public var lastCheckedAt: Date?
    public var error: String?
    public init(pageURL: String, optionID: String, label: String, episode: Int, now: Date = Date()) {
        self.pageURL = pageURL; self.optionID = optionID; self.label = label; lastEpisode = episode; lastCheckedAt = now
    }
}
public struct ReleaseNotice: Codable, Equatable, Identifiable {
    public var id: String
    public var subscriptionID: UUID
    public var title: String
    public var episode: Int
    public var previousEpisode: Int
    public var url: String
    public var foundAt: Date
    public var read = false
    public init(subscription: ReleaseSubscription, entryTitle: String, episode: Int, url: String, now: Date = Date()) {
        id = "\(subscription.id.uuidString)-\(episode)"; subscriptionID = subscription.id
        title = entryTitle; self.episode = episode; previousEpisode = subscription.lastEpisode ?? episode
        self.url = url; foundAt = now
    }
}
public struct SourceOption: Equatable, Identifiable {
    public var id: String
    public var label: String
    public var episode: Int
    public var translationID: Int?
    public var translationKey: String?
    public var player: String
    public init(id: String, label: String, episode: Int, translationID: Int? = nil, translationKey: String? = nil, player: String = "kodik") {
        self.id = id; self.label = label; self.episode = episode; self.translationID = translationID; self.translationKey = translationKey; self.player = player
    }
}
public struct SourcePage: Equatable {
    public var title: String
    public var url: String
    public var coverURL: String?
    public var options: [SourceOption]
    public func watchURL(for option: SourceOption, episode: Int) -> String {
        var components = URLComponents(string:url)!
        // Публичная страница поддерживает episode и translation. Видеопотоки не извлекаются.
        components.queryItems = [.init(name:"episode",value:String(episode))]
        if let translation = option.translationKey { components.queryItems?.append(.init(name:"translation",value:translation)) }
        components.queryItems?.append(.init(name:"player",value:option.player))
        components.fragment = "player-section"
        return components.url?.absoluteString ?? url
    }
}

public enum AnivibePageParser {
    public static func canonicalURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", ["anivibe.pro","www.anivibe.pro"].contains(parts.host?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.range(of:#"^/anime/[0-9]+(?:-[a-zA-Z0-9_-]+)?/?$"#,options:.regularExpression) != nil else { return nil }
        parts.host = "anivibe.pro"; parts.query = nil; parts.fragment = nil
        return parts.url
    }
    public static func parse(_ html: String, url: String) throws -> SourcePage {
        guard let canonical = canonicalURL(url), html.utf8.count <= 8_000_000 else {
            throw ShelfError.invalid("Страница AniVibe не содержит распознаваемого списка серий. Формат сайта мог измениться; текущие данные сохранены.")
        }
        let raw = jsonValue(in:html,after:"const kodikData =") ?? "{}"
        let root = (try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any]) ?? [:]
        let rows = root["translations"] as? [[String:Any]] ?? []
        let material = root["material_data"] as? [String:Any] ?? [:]
        let title = (material["anime_title"] as? String) ?? (material["title"] as? String) ?? meta("og:title",in:html) ?? "AniVibe"
        var seen = Set<String>(); var options: [SourceOption] = []
        for row in rows {
            guard let id = row["id"] as? Int, let label = row["title"] as? String,
                  let episode = row["last_episode"] as? Int, (1...1_000_000).contains(episode) else { continue }
            let season = row["season"] as? Int
            let key = "kodik-\(id)-\(season ?? 0)"
            guard seen.insert(key).inserted else { continue }
            options.append(SourceOption(id:key,label:"\(label)" + (season.map { " · сезон \($0)" } ?? "") + " · Kodik",episode:episode,translationID:id,translationKey:label))
        }
        // Только публичные номера серий и названия дорожек; коды видео и signed_params не сохраняются.
        if let raw = jsonValue(in:html,after:"window.__vidozaData = window.__unpackVidozaGroups("),
           let groups = try? JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [[String:Any]] {
            for group in groups {
                guard let author = group["vn"] as? String, author.count <= 80,
                      let episodes = group["eps"] as? [[String:Any]],
                      let last = episodes.compactMap({$0["e"] as? Int}).filter({(1...1_000_000).contains($0)}).max() else { continue }
                let type = group["tt"] as? String ?? "voice", language = group["tl"] as? String ?? "ru"
                guard ["voice","sub","raw"].contains(type), language.count <= 10 else { continue }
                let track = "\(type)||\(language)||\(author)", key = "anivibe-\(track)"
                guard seen.insert(key).inserted else { continue }
                let kind = type == "sub" ? "субтитры" : (type == "raw" ? "оригинал" : "озвучка")
                options.append(SourceOption(id:key,label:"\(author) · \(kind) \(language) · AniVibe",episode:last,translationKey:track,player:"anivibe"))
            }
        }
        guard !options.isEmpty else { throw ShelfError.invalid("На странице пока нет доступных данных о сериях для отслеживания.") }
        return SourcePage(title:decodeEntities(title),url:canonical.absoluteString,coverURL:meta("og:image",in:html),options:options)
    }
    /// Извлекает один JSON-объект без выполнения JavaScript и без чтения закрытых API сайта.
    public static func jsonValue(in text: String, after marker: String) -> String? {
        guard let markerRange = text.range(of:marker), let first = text[markerRange.upperBound...].firstIndex(where:{ !$0.isWhitespace }), text[first] == "{" || text[first] == "[" else { return nil }
        var depth = 0, inString = false, escaped = false
        var index = first
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true }
            else if ch == "{" || ch == "[" { depth += 1 }
            else if ch == "}" || ch == "]" { depth -= 1; if depth == 0 { return String(text[first...index]) } }
            index = text.index(after:index)
        }
        return nil
    }
    private static func meta(_ name: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern:#"<meta\b[^>]*>"#,options:.caseInsensitive) else { return nil }
        let ns = html as NSString
        for match in regex.matches(in:html,range:NSRange(location:0,length:ns.length)) {
            let tag = ns.substring(with:match.range)
            if tag.range(of:"\"\(name)\"",options:.caseInsensitive) != nil,
               let r = try? NSRegularExpression(pattern:#"content\s*=\s*"([^"]*)""#,options:.caseInsensitive),
               let m = r.firstMatch(in:tag,range:NSRange(location:0,length:(tag as NSString).length)) { return decodeEntities((tag as NSString).substring(with:m.range(at:1))) }
        }
        return nil
    }
    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of:"&amp;",with:"&").replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:"&#039;",with:"'").replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">")
    }
}

public enum ReleaseTracker {
    /// Первая проверка устанавливает базу. Уведомления только о последующих новых сериях.
    @discardableResult public static func observe(_ page: SourcePage, entry: inout Entry, subscriptionID: UUID, now: Date = Date()) throws -> ReleaseNotice? {
        guard var subscriptions = entry.subscriptions, let i = subscriptions.firstIndex(where:{$0.id == subscriptionID}), subscriptions[i].enabled else { return nil }
        let old = subscriptions[i]
        guard let option = page.options.first(where:{$0.id == old.optionID}) else { throw ShelfError.invalid("Выбранная озвучка или сезон отсутствует на странице. Выберите источник заново.") }
        guard old.lastEpisode == nil || option.episode >= old.lastEpisode! else { throw ShelfError.invalid("Номер серии в источнике уменьшился. Проверьте сезон и озвучку; прежняя отметка сохранена.") }
        subscriptions[i].lastCheckedAt = now; subscriptions[i].lastEpisode = option.episode; subscriptions[i].error = nil
        entry.subscriptions = subscriptions
        guard let previous = old.lastEpisode, option.episode > previous else { return nil }
        let notice = ReleaseNotice(subscription:old,entryTitle:entry.title,episode:option.episode,url:page.watchURL(for:option,episode:option.episode),now:now)
        var notices = entry.releaseNotices ?? []
        guard !notices.contains(where:{$0.id == notice.id}) else { return nil }
        notices.insert(notice,at:0); entry.releaseNotices = Array(notices.prefix(100)); return notice
    }
}
