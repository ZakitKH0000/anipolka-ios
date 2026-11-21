import Foundation

/// How a connected dub behaves: the main one rings, a backup rings only when the main dub is late, a quiet one never rings.
public enum SourceRole: String, CaseIterable, Identifiable {
    case main, backup, silent
    public init(_ raw: String?) { self = raw.flatMap(SourceRole.init(rawValue:)) ?? .main }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .main: return "Основная"
        case .backup: return "Запасная"
        case .silent: return "Без уведомлений"
        }
    }
    public var hint: String {
        switch self {
        case .main: return "Уведомляет о каждой новой серии."
        case .backup: return "Уведомляет, только если в основной озвучке этой серии ещё нет."
        case .silent: return "Серии видны в списке, но уведомлений нет."
        }
    }
}

extension ReleaseSubscription {
    /// The source's latest episode in the user's own numbering.
    public var userEpisode: Int? { lastEpisode.map { $0 - (offset ?? 0) } }
    public var isTelegram: Bool { TelegramChannel.canonicalURL(pageURL) != nil }
}

/// Pages and links the app may store as episode sources: AniVibe pages and public Telegram channels.
public enum ReleaseSources {
    public static func isValidPage(_ address: String) -> Bool {
        AnivibePageParser.canonicalURL(address) != nil || TelegramChannel.canonicalURL(address) != nil
    }
    public static func isValidLink(_ address: String) -> Bool {
        AnivibePageParser.canonicalURL(address) != nil || TelegramChannel.isPostURL(address)
    }
}

/// AniVibe address actually requested. Stored links keep anivibe.pro, so a mirror can be switched back at any time.
public enum AnivibeMirror {
    public static let defaultHost = "anivibe.pro"
    public static var host = defaultHost
    /// «anivibe.xyz», «www.anivibe.xyz» or a full link → a lowercase host name; nil when it is not a plain domain.
    public static func normalizedHost(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !value.contains("://") { value = "https://" + value }
        guard let parts = URLComponents(string: value), parts.scheme == "https" || parts.scheme == "http",
              parts.user == nil, parts.password == nil, parts.port == nil, var host = parts.host, host.count <= 100 else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil else { return nil }
        return host
    }
    public static func isKnown(_ host: String?) -> Bool {
        guard var h = host?.lowercased() else { return false }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h == defaultHost || h == self.host
    }
    /// The same page on the mirror in use.
    public static func live(_ url: URL) -> URL {
        guard host != defaultHost, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), isKnown(parts.host) else { return url }
        parts.host = host
        return parts.url ?? url
    }
    public static func live(_ address: String) -> String {
        guard let url = URL(string: address) else { return address }
        return live(url).absoluteString
    }
}

/// Public preview of a Telegram channel (t.me/s/name): dub studios post «Серия: 10-16» or «— 10 серия».
public enum TelegramChannel {
    static let namePattern = #"^[A-Za-z][A-Za-z0-9_]{3,31}$"#
    /// «@fumodub», «fumodub», «t.me/fumodub» or «https://t.me/s/fumodub» → https://t.me/s/fumodub.
    public static func canonicalURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        var name = value
        if value.contains("t.me/") || value.contains("telegram.me/") {
            if !value.contains("://") { value = "https://" + value }
            guard let parts = URLComponents(string: value), parts.scheme == "https",
                  ["t.me", "www.t.me", "telegram.me"].contains(parts.host?.lowercased() ?? ""), parts.user == nil, parts.port == nil else { return nil }
            var path = parts.path.split(separator: "/").map(String.init)
            if path.first == "s" { path.removeFirst() }
            guard path.count == 1 else { return nil }
            name = path[0]
        }
        guard name.range(of: namePattern, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://t.me/s/\(name)")
    }
    public static func channel(of address: String) -> String? {
        canonicalURL(address).map { String($0.path.split(separator: "/").last ?? "") }
    }
    /// A link to one post: https://t.me/name/123.
    public static func isPostURL(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), parts.scheme == "https", parts.host == "t.me", parts.query == nil else { return false }
        let path = parts.path.split(separator: "/").map(String.init)
        return path.count == 2 && path[0].range(of: namePattern, options: .regularExpression) != nil && Int(path[1]) != nil
    }
    /// The title words to look for are kept in the option id: «telegram:Пощади меня, великий господин! 3».
    public static func optionID(keyword: String) -> String { "telegram:" + String(keyword.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140)) }
    public static func keyword(_ optionID: String) -> String? {
        guard optionID.hasPrefix("telegram:") else { return nil }
        let value = String(optionID.dropFirst("telegram:".count))
        return value.isEmpty ? nil : value
    }

    public struct Post: Equatable {
        public var id: String
        public var text: String
    }
    /// Posts of the preview page with their text; markup, links and media are dropped.
    public static func posts(_ html: String) -> [Post] {
        guard html.utf8.count <= 8_000_000 else { return [] }
        var result: [Post] = []
        var rest = html[...]
        while let mark = rest.range(of: "data-post=\"") {
            guard let close = rest[mark.upperBound...].firstIndex(of: "\"") else { break }
            let id = String(rest[mark.upperBound..<close])
            rest = rest[close...]
            let next = rest.range(of: "data-post=\"")?.lowerBound ?? rest.endIndex
            let block = rest[..<next]
            if let open = block.range(of: "tgme_widget_message_text"), let start = block[open.upperBound...].firstIndex(of: ">") {
                let body = block[block.index(after: start)...]
                let end = body.range(of: "</div>")?.lowerBound ?? body.endIndex
                result.append(Post(id: id, text: plain(String(body[..<end]))))
            }
            rest = rest[next...]
        }
        return result
    }
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
    }
    /// The highest episode number a post announces: «Серия: 10-16» → 16, «— 8 серия» → 8, «Эпизод 5» → 5.
    public static func episode(in text: String) -> Int? {
        let patterns = [#"(?<!\p{L})(?:серия|серии|эпизод|эпизоды|episode|ep\.?)\s*[:№#]?\s*(\d{1,4})(?:\s*[-–—]\s*(\d{1,4}))?(?!\d)"#,
                        #"(?<!\d)(\d{1,4})(?:\s*[-–—]\s*(\d{1,4}))?\s*(?:-?(?:я|ая)\s+)?(?:серия|серии|эпизод)(?!\p{L})"#]
        var best: Int?
        let ns = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                    if let n = Int(ns.substring(with: match.range(at: group))), (1...10_000).contains(n) { best = max(best ?? 0, n) }
                }
            }
        }
        return best
    }
    /// The title words must stand in the first lines of the post, where studios put the title.
    public static func matches(_ text: String, keyword: String) -> Bool {
        let words = keyword.components(separatedBy: "|").map(TitleIdentity.normalized).filter { $0.count >= 3 }
        guard !words.isEmpty else { return false }
        let head = TitleIdentity.normalized(text.components(separatedBy: "\n").prefix(3).joined(separator: " "))
        return words.contains { " \(head) ".contains(" \($0) ") }
    }
    /// One option: the newest episode of the title among the visible posts. Without a fresh post the known episode stays.
    public static func page(_ html: String, url: String, keyword: String, label: String, known: Int? = nil) throws -> SourcePage {
        guard let canonical = canonicalURL(url), let name = channel(of: url) else { throw ShelfError.invalid("Укажите канал: @название или ссылку t.me/название.") }
        let found = posts(html).filter { matches($0.text, keyword: keyword) }.compactMap { post in episode(in: post.text).map { (post, $0) } }
        let best = found.max { $0.1 < $1.1 }
        guard let episode = [best?.1, known].compactMap({ $0 }).max() else {
            throw ShelfError.invalid("В последних постах @\(name) нет «\(keyword)» с номером серии. Проверьте название так, как его пишет студия.")
        }
        let link = best.flatMap { b -> String? in
            let parts = b.0.id.split(separator: "/")
            return parts.count == 2 ? "https://t.me/\(parts[0])/\(parts[1])" : nil
        }
        let option = SourceOption(id: optionID(keyword: keyword), label: label, episode: episode, player: "telegram", link: link)
        return SourcePage(title: "@\(name)", url: canonical.absoluteString, coverURL: nil, options: [option])
    }
}

/// Bangumi (bgm.tv): Chinese and Japanese broadcast dates of every episode, reachable without VPN.
public struct BangumiInfo: Codable, Equatable {
    /// Bangumi subject; 0 when nothing matched the native title.
    public var id: Int
    public var checkedAt: Date
    public var aired: Int?
    public var nextEpisode: Int?
    /// «yyyy-MM-dd», China time.
    public var nextDate: String?
    public init(id: Int, checkedAt: Date, aired: Int? = nil, nextEpisode: Int? = nil, nextDate: String? = nil) {
        self.id = id; self.checkedAt = checkedAt; self.aired = aired; self.nextEpisode = nextEpisode; self.nextDate = nextDate
    }
    public var url: String { "https://bgm.tv/subject/\(id)" }
}

public enum Bangumi {
    public static let host = "api.bgm.tv"
    /// The public search that also finds Chinese titles.
    public static func searchURL(_ title: String) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else { return nil }
        return URL(string: "https://api.bgm.tv/search/subject/\(encoded)?type=2&responseGroup=small&max_results=10")
    }
    /// Only a subject whose name is exactly the native title is taken; nothing is guessed.
    public static func pickSubject(_ data: Data, native: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = root["list"] as? [[String: Any]] else { return nil }
        let key = TitleIdentity.normalized(native)
        guard !key.isEmpty else { return nil }
        return list.first { item in
            [item["name"], item["name_cn"]].compactMap { $0 as? String }.contains { TitleIdentity.normalized($0) == key }
        }.flatMap { ($0["id"] as? NSNumber)?.intValue }
    }
    public static func episodesURL(_ id: Int, offset: Int = 0) -> URL {
        URL(string: "https://api.bgm.tv/v0/episodes?subject_id=\(id)&type=0&limit=200&offset=\(max(0, offset))")!
    }
    public static func total(_ data: Data) -> Int? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["total"] as? NSNumber)?.intValue }
    }
    /// Today's date in China, where donghua premiere.
    public static func today(_ now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: now)
    }
    /// Episodes out by today and the next one with its date.
    public static func parseEpisodes(_ data: Data, today: String) throws -> (aired: Int?, next: Int?, nextDate: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = root["data"] as? [[String: Any]] else {
            throw ShelfError.invalid("Bangumi вернул неожиданный ответ.")
        }
        var aired: Int?, next: (Int, String)?
        for item in list {
            guard let number = ((item["ep"] as? NSNumber) ?? (item["sort"] as? NSNumber))?.intValue, (1...10_000).contains(number),
                  let date = item["airdate"] as? String, date.count == 10 else { continue }
            if date <= today { aired = max(aired ?? 0, number) }
            else if next == nil || date < next!.1 || (date == next!.1 && number < next!.0) { next = (number, date) }
        }
        return (aired, next?.0, next?.1)
    }
    /// Bangumi fills in what Shikimori lags behind on: the aired count and the number of the next episode.
    public static func merge(_ info: AiringInfo, _ bangumi: BangumiInfo?) -> AiringInfo {
        var result = info
        result.bangumi = bangumi
        guard let b = bangumi, b.id > 0 else { return result }
        if let aired = b.aired, aired > (result.episodesAired ?? 0), aired <= (result.episodes ?? 10_000) { result.episodesAired = aired }
        if result.nextEpisode == nil, let n = b.nextEpisode, n > (result.episodesAired ?? 0) {
            if let at = result.nextEpisodeAt, let date = b.nextDate { if today(at) == date { result.nextEpisode = n } }
            else { result.nextEpisode = n }
        }
        return result
    }
    /// «Bangumi: вышла 36 · 37-я — 22 ноября (Китай)».
    public static func line(_ b: BangumiInfo) -> String? {
        guard b.id > 0 else { return nil }
        var parts: [String] = []
        if let aired = b.aired { parts.append("Bangumi: вышла \(aired)") } else { parts.append("Bangumi") }
        if let n = b.nextEpisode, let date = b.nextDate {
            let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.dateFormat = "yyyy-MM-dd"; input.timeZone = TimeZone(identifier: "Asia/Shanghai")
            let output = DateFormatter(); output.locale = Locale(identifier: "ru_RU"); output.dateFormat = "d MMMM"; output.timeZone = TimeZone(identifier: "Asia/Shanghai")
            parts.append("\(n)-я — " + (input.date(from: date).map(output.string(from:)) ?? date) + " (Китай)")
        }
        return parts.joined(separator: " · ")
    }
}
