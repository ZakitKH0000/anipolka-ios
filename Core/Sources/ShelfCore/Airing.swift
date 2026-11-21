import Foundation

/// Next season or other continuation found in the catalogue.
public struct SequelHint: Codable, Equatable {
    public var id: Int
    public var title: String
    public var originalTitle: String
    /// Catalogue status: «anons», «ongoing» or «released».
    public var status: String
    public var coverURL: String
    /// First air date as «yyyy-MM-dd», when known.
    public var airedOn: String?
    public init(id: Int, title: String, originalTitle: String, status: String, coverURL: String, airedOn: String? = nil) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.status = status; self.coverURL = coverURL; self.airedOn = airedOn
    }
}

/// Broadcast data of a title from Shikimori: how many episodes are out and when the next one airs.
public struct AiringInfo: Codable, Equatable {
    public var checkedAt: Date
    public var status: String
    /// Planned total; nil when the catalogue does not know it yet.
    public var episodes: Int?
    public var episodesAired: Int?
    /// Original (Japanese or Chinese) broadcast time; dubs usually follow later.
    public var nextEpisodeAt: Date?
    public var sequel: SequelHint?
    /// Shikimori franchise key, shared by every season of the story.
    public var franchise: String?
    /// Number of the next episode when AniList announces it.
    public var nextEpisode: Int?
    /// AniLibria's dub schedule, when the title is in it.
    public var libria: LibriaInfo?
    /// Native (Chinese or Japanese) title from Shikimori, used to find the title on Bangumi.
    public var nativeTitle: String?
    /// Episode dates from Bangumi.
    public var bangumi: BangumiInfo?
    public init(checkedAt: Date, status: String, episodes: Int? = nil, episodesAired: Int? = nil, nextEpisodeAt: Date? = nil, sequel: SequelHint? = nil, franchise: String? = nil, nextEpisode: Int? = nil, libria: LibriaInfo? = nil) {
        self.checkedAt = checkedAt; self.status = status; self.episodes = episodes; self.episodesAired = episodesAired; self.nextEpisodeAt = nextEpisodeAt; self.sequel = sequel; self.franchise = franchise
        self.nextEpisode = nextEpisode; self.libria = libria
    }
}

/// A day of the release calendar: titles with an exact time first, then the user's own release days.
public struct CalendarItem: Identifiable {
    public var entry: Entry
    public var episode: Int?
    public var at: Date?
    public var id: UUID { entry.id }
}
public struct CalendarDay: Identifiable {
    public var date: Date
    public var items: [CalendarItem]
    public var id: Date { date }
}

public enum Airing {
    public static let anons = "anons", ongoing = "ongoing", released = "released"
    static let statuses: Set<String> = [anons, ongoing, released]
    static let sequelKinds: Set<String> = ["tv", "movie", "ona", "ova", "special", "tv_special"]

    /// GraphQL request body for up to 50 titles; the answer is read by `parse`.
    public static func query(_ ids: [Int]) -> Data {
        let q = "query($ids: String!) { animes(ids: $ids, limit: 50) { id franchise japanese status episodes episodesAired nextEpisodeAt related { relationKind anime { id name russian status kind airedOn { date } poster { mainUrl } } } } }"
        let body: [String: Any] = ["query": q, "variables": ["ids": ids.prefix(50).map(String.init).joined(separator: ",")]]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    public static func parse(_ data: Data, now: Date = Date()) throws -> [Int: AiringInfo] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["data"] as? [String: Any])?["animes"] as? [[String: Any]] else {
            throw ShelfError.invalid("Каталог вернул неожиданный ответ.")
        }
        let iso = ISO8601DateFormatter()
        var result: [Int: AiringInfo] = [:]
        for a in list {
            guard let id = string(a["id"]).flatMap({ Int($0) }), let status = a["status"] as? String, statuses.contains(status) else { continue }
            let next = (a["nextEpisodeAt"] as? String).flatMap { iso.date(from: $0) }
            var sequel: SequelHint?
            for r in (a["related"] as? [[String: Any]]) ?? [] {
                guard r["relationKind"] as? String == "sequel", let s = r["anime"] as? [String: Any],
                      let sid = string(s["id"]).flatMap({ Int($0) }), sequelKinds.contains((s["kind"] as? String) ?? "") else { continue }
                let name = (s["name"] as? String) ?? ""
                let russian = (s["russian"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let poster = ((s["poster"] as? [String: Any])?["mainUrl"] as? String) ?? ""
                let aired = (s["airedOn"] as? [String: Any])?["date"] as? String
                sequel = SequelHint(id: sid, title: String((russian ?? name).prefix(500)), originalTitle: String(name.prefix(500)),
                                    status: statuses.contains((s["status"] as? String) ?? "") ? s["status"] as! String : anons,
                                    coverURL: poster.hasPrefix("https://") ? poster : "", airedOn: aired?.count == 10 ? aired : nil)
                break
            }
            let episodes = int(a["episodes"]).flatMap { $0 > 0 ? $0 : nil }
            let aired = int(a["episodesAired"]).flatMap { $0 > 0 ? $0 : nil }
            result[id] = AiringInfo(checkedAt: now, status: status, episodes: episodes, episodesAired: aired,
                                    nextEpisodeAt: (status == ongoing || status == anons) ? next : nil, sequel: sequel,
                                    franchise: (a["franchise"] as? String).map { $0.count > 200 ? "" : $0 } ?? "")
            if let native = (a["japanese"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !native.isEmpty, native.count <= 200 { result[id]?.nativeTitle = native }
        }
        return result
    }

    /// Ongoing titles are refreshed every 6 hours (and soon after the announced time), finished ones weekly.
    public static func needsRefresh(_ e: Entry, now: Date = Date()) -> Bool {
        guard e.sourceID != nil, e.status != .dropped else { return false }
        guard let info = e.airing, info.franchise != nil else { return true }
        let age = now.timeIntervalSince(info.checkedAt)
        if let next = info.nextEpisodeAt, now > next.addingTimeInterval(1800), age > 1800 { return true }
        switch info.status {
        case ongoing: return age >= 6 * 3600
        case anons: return age >= 24 * 3600
        default: return age >= 7 * 86400
        }
    }

    /// Saves fresh data; empty release days are filled from the broadcast weekday.
    public static func apply(_ e: Entry, _ info: AiringInfo, calendar: Calendar = .current) -> Entry {
        var next = e; next.airing = info
        // Shikimori does not know Bangumi and AniLibria data; the last known stays until they are checked again.
        if info.bangumi == nil { next.airing?.bangumi = e.airing?.bangumi }
        if info.libria == nil { next.airing?.libria = e.airing?.libria }
        if let key = info.franchise, !key.isEmpty { next.franchise = key }
        if (e.releaseDays ?? []).isEmpty, info.status == ongoing, let at = info.nextEpisodeAt {
            next.releaseDays = [ReleasePlanner.weekday(of: at, calendar: calendar)]
        }
        return next
    }

    public static func upcoming(_ e: Entry, now: Date = Date()) -> Date? {
        guard e.status != .dropped, let at = e.airing?.nextEpisodeAt, at > now.addingTimeInterval(-6 * 3600) else { return nil }
        return at
    }

    /// Number of the next episode to air, when the catalogue announces a time.
    public static func nextEpisode(_ e: Entry, now: Date = Date()) -> Int? {
        guard upcoming(e, now: now) != nil, let info = e.airing else { return nil }
        return info.nextEpisode ?? (info.episodesAired ?? 0) + 1
    }

    /// «через 2 д 5 ч», «через 40 мин», «уже вышла».
    public static func countdown(_ at: Date, now: Date = Date()) -> String {
        let seconds = Int(at.timeIntervalSince(now))
        guard seconds > 0 else { return "уже вышла" }
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "через \(days) д" + (hours > 0 ? " \(hours) ч" : "") }
        if hours > 0 { return "через \(hours) ч" + (minutes > 0 ? " \(minutes) мин" : "") }
        return "через \(max(1, minutes)) мин"
    }

    /// Short form for a badge on a cover: «2 д», «5 ч», «40 мин».
    public static func shortCountdown(_ at: Date, now: Date = Date()) -> String {
        let seconds = Int(at.timeIntervalSince(now))
        guard seconds > 0 else { return "вышла" }
        if seconds >= 86400 { return "\(seconds / 86400) д" }
        if seconds >= 3600 { return "\(seconds / 3600) ч" }
        return "\(max(1, seconds / 60)) мин"
    }

    /// «сегодня, 18:30», «завтра, 09:00», «сб, 23 ноября, 18:30».
    public static func moment(_ at: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = DateFormatter(); time.locale = Locale(identifier: "ru_RU"); time.calendar = calendar; time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        let day: String
        if calendar.isDate(at, inSameDayAs: now) { day = "сегодня" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(at, inSameDayAs: tomorrow) { day = "завтра" }
        else { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "EE, d MMMM"; day = f.string(from: at) }
        return "\(day), \(time.string(from: at))"
    }

    static func countWord(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "серий" }
        if ones == 1 { return "серия" }
        return (2...4).contains(ones) ? "серии" : "серий"
    }

    /// «Выходит · вышло 27 из 28 серий», «Завершён · 28 серий», «Анонс».
    public static func progressText(_ info: AiringInfo) -> String {
        switch info.status {
        case anons: return "Анонс" + (info.nextEpisodeAt.map { " · премьера \(moment($0))" } ?? "")
        case ongoing:
            let aired = info.episodesAired ?? 0
            return "Выходит · вышло \(aired)" + (info.episodes.map { " из \($0)" } ?? "") + " " + countWord(info.episodes ?? aired)
        default:
            return "Завершён" + ((info.episodes ?? info.episodesAired).map { " · \($0) \(countWord($0))" } ?? "")
        }
    }

    /// Episodes already broadcast but not yet watched, by the catalogue; nil when none or unknown.
    public static func aired(_ e: Entry) -> Int? {
        guard let info = e.airing, e.status != .completed else { return nil }
        let total = info.status == released ? (info.episodes ?? info.episodesAired) : info.episodesAired
        guard let count = total.map({ $0 - e.seasonEpisode }), (1...9999).contains(count) else { return nil }
        return count
    }

    /// The continuation to suggest, unless it is already in the collection or was dismissed.
    public static func sequelSuggestion(_ e: Entry, in snapshot: Snapshot) -> SequelHint? {
        guard let hint = e.airing?.sequel, e.status != .dropped, e.dismissedSequelID != hint.id else { return nil }
        // Exact names only: the previous season's name is usually a prefix of the sequel's.
        let others = snapshot.entries.filter { $0.id != e.id }
        if others.contains(where: { $0.sourceID == hint.id }) { return nil }
        if [hint.title, hint.originalTitle].contains(where: { TitleMatcher.existing($0, in: others) != nil }) { return nil }
        return hint
    }

    public static func sequelEntry(_ hint: SequelHint, after previous: UUID? = nil, now: Date = Date()) -> Entry {
        var e = Entry(title: hint.title)
        e.originalTitle = hint.originalTitle; e.status = .planned; e.sourceID = hint.id
        e.sourceURL = "https://shikimori.io/animes/\(hint.id)"; e.coverURL = hint.coverURL; e.updatedAt = now; e.coverLookupDisabled = false
        let alias = hint.originalTitle
        if !alias.isEmpty, alias != hint.title { e.aliases = [alias] }
        if let previous { e.relatedIDs = [previous] }
        return e
    }

    public static func sequelLabel(_ hint: SequelHint) -> String {
        switch hint.status {
        case anons:
            var label = "Анонсировано продолжение"
            if let day = hint.airedOn {
                let parse = DateFormatter(); parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd"
                let show = DateFormatter(); show.locale = Locale(identifier: "ru_RU"); show.dateFormat = "d MMMM yyyy"
                label += " · " + (parse.date(from: day).map { show.string(from: $0) } ?? day)
            }
            return label
        case ongoing: return "Выходит продолжение"
        default: return "Вышло продолжение"
        }
    }

    /// Seven days from today: exact broadcast times from the catalogue, then titles on the user's release days.
    public static func calendar(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [CalendarDay] {
        let today = calendar.startOfDay(for: now)
        let active = entries.filter { $0.status == .watching || $0.status == .planned }
        return (0..<7).compactMap { offset -> CalendarDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let timed = active.compactMap { e -> CalendarItem? in
                guard let at = upcoming(e, now: now), calendar.isDate(at, inSameDayAs: day) else { return nil }
                return CalendarItem(entry: e, episode: nextEpisode(e, now: now), at: at)
            }.sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
            let weekday = calendar.component(.weekday, from: day)
            // Titles without a known broadcast time appear on the user's own release days.
            let planned = active.filter { ($0.releaseDays ?? []).contains(weekday) && upcoming($0, now: now) == nil }
                .map { CalendarItem(entry: $0, episode: nil, at: nil) }
            return CalendarDay(date: day, items: timed + planned)
        }
    }
}

/// Keeps the new-episode inbox tidy: watched episodes are read, old read notices go away.
public enum NoticeInbox {
    public static let keepReadDays = 30

    public static func tidy(_ entry: Entry, now: Date = Date()) -> Entry {
        guard let notices = entry.releaseNotices, !notices.isEmpty else { return entry }
        let cutoff = now.addingTimeInterval(-Double(keepReadDays) * 86400)
        let next = notices.map { n -> ReleaseNotice in
            var n = n; if !n.read && n.episode <= entry.seasonEpisode { n.read = true }; return n
        }.filter { !$0.read || $0.foundAt > cutoff }
        guard next != notices else { return entry }
        var e = entry; e.releaseNotices = next; return e
    }

    public static func tidy(_ snapshot: Snapshot, now: Date = Date()) -> Snapshot {
        var next = snapshot
        next.entries = snapshot.entries.map { tidy($0, now: now) }
        return next
    }

    public static func unread(_ snapshot: Snapshot) -> Int {
        snapshot.entries.reduce(0) { $0 + ($1.releaseNotices ?? []).filter { !$0.read }.count }
    }

    public static func markAllRead(_ s: inout Snapshot) {
        for i in s.entries.indices where (s.entries[i].releaseNotices ?? []).contains(where: { !$0.read }) {
            s.entries[i].releaseNotices = s.entries[i].releaseNotices?.map { var n = $0; n.read = true; return n }
        }
    }
    public static func markRead(_ s: inout Snapshot, entryID: UUID, noticeID: String) {
        guard let i = s.entries.firstIndex(where: { $0.id == entryID }), let j = s.entries[i].releaseNotices?.firstIndex(where: { $0.id == noticeID }) else { return }
        s.entries[i].releaseNotices?[j].read = true
    }
    public static func remove(_ s: inout Snapshot, entryID: UUID, noticeID: String) {
        guard let i = s.entries.firstIndex(where: { $0.id == entryID }) else { return }
        s.entries[i].releaseNotices?.removeAll { $0.id == noticeID }
    }
    public static func removeRead(_ s: inout Snapshot) {
        for i in s.entries.indices { s.entries[i].releaseNotices?.removeAll { $0.read } }
    }
    public static func removeAll(_ s: inout Snapshot) {
        for i in s.entries.indices where s.entries[i].releaseNotices != nil { s.entries[i].releaseNotices = [] }
    }
}
