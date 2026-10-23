import Foundation

public enum WatchStatus: String, Codable, CaseIterable, Identifiable {
    case watching = "Смотрю", planned = "На потом", completed = "Завершено", dropped = "Заброшено"
    public var id: String { rawValue }
}
public enum Theme: String, Codable, CaseIterable { case dark = "Тёмное", light = "Светлое", system = "Как на iPhone" }
public enum Layout: String, Codable, CaseIterable { case list = "Компактный список", grid = "Сетка обложек" }
public enum ShelfSort: String, Codable, CaseIterable { case recent = "По последнему просмотру", title = "По названию", manual = "Вручную" }
public struct Preferences: Codable, Equatable {
    public var theme: Theme = .dark
    public var layout: Layout = .list
    public var sort: ShelfSort = .recent
    public var showContinue = true
    public var haptics = true
    public var wifiOnly = false
    public init() {}
}
public struct Entry: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var title: String
    public var originalTitle = ""
    public var episode = 0
    public var season: Int? = nil
    public var status: WatchStatus = .watching
    public var favorite = false
    public var note = ""
    public var watchURL = ""
    public var sourceURL = ""
    public var sourceID: Int? = nil
    public var coverURL = ""
    public var coverData: Data? = nil
    public var updatedAt = Date()
    public var watchedAt: Date? = nil
    public init(title: String, episode: Int = 0) { self.title = title; self.episode = episode }
    public var displayTitle: String { title + (favorite && !title.contains("⭐") && !title.contains("★") ? " ★" : "") }
    public var subtitle: String { (season.map { "Сезон \($0) · " } ?? "") + "Последняя серия: \(episode)" }
}
public struct Snapshot: Codable, Equatable {
    public var format = "AniPolka"
    public var version = 1
    public var entries: [Entry] = []
    public var preferences = Preferences()
    public init() {}
    public func validated() throws -> Snapshot {
        guard format == "AniPolka", version == 1 else { throw ShelfError.invalid("Неподдерживаемый формат резервной копии.") }
        guard entries.count <= 2000, Set(entries.map(\.id)).count == entries.count else { throw ShelfError.invalid("Слишком много записей или повторяющиеся идентификаторы.") }
        for e in entries {
            guard !e.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, e.title.count <= 500,
                  (0...1_000_000).contains(e.episode), e.season == nil || (1...10000).contains(e.season!),
                  e.note.count <= 20000, e.watchURL.count <= 4000, e.coverURL.count <= 4000,
                  (e.coverData?.count ?? 0) <= 3_000_000 else { throw ShelfError.invalid("Недопустимые данные записи «\(e.title.prefix(60))».") }
        }
        return self
    }
    public func encoded() throws -> Data {
        _ = try validated()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 150_000_000 else { throw ShelfError.invalid("Коллекция превысила 150 МБ. Уменьшите количество обложек перед сохранением.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 150_000_000 else { throw ShelfError.invalid("Файл больше 150 МБ.") }
        do { return try JSONDecoder().decode(Snapshot.self, from: data).validated() }
        catch let error as ShelfError { throw error }
        catch { throw ShelfError.invalid("Не удалось прочитать копию АниПолки. Текущая коллекция сохранена.") }
    }
    public func visible(query: String = "", status: WatchStatus? = nil, favorites: Bool = false) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = entries.filter { e in
            (status == nil || e.status == status) && (!favorites || e.favorite) &&
            (needle.isEmpty || e.title.localizedCaseInsensitiveContains(needle) || e.originalTitle.localizedCaseInsensitiveContains(needle) || e.note.localizedCaseInsensitiveContains(needle))
        }
        switch preferences.sort {
        case .manual: return result
        case .title: return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent: return result.sorted { ($0.watchedAt ?? .distantPast) == ($1.watchedAt ?? .distantPast) ? $0.updatedAt > $1.updatedAt : ($0.watchedAt ?? .distantPast) > ($1.watchedAt ?? .distantPast) }
        }
    }
    public mutating func merge(_ backup: Snapshot) {
        let ids = Set(entries.map(\.id)); entries += backup.entries.filter { !ids.contains($0.id) }
    }
    public mutating func reorder(ids: [UUID]) {
        let lookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        guard ids.count == entries.count, Set(ids) == Set(entries.map(\.id)) else { return }
        entries = ids.compactMap { lookup[$0] }
    }
}
public enum ShelfError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public struct EpisodeUndo {
    public let id: UUID
    public let previous: Entry
    public let applied: Entry
}
public final class ShelfRepository {
    public let url: URL
    public private(set) var snapshot: Snapshot
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) { snapshot = try Snapshot.decode(Data(contentsOf: url)) }
        else { snapshot = Snapshot() }
    }
    public func commit(_ next: Snapshot) throws {
        let data = try next.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic replacement: publish in-memory state only after the disk write succeeds.
        try data.write(to: url, options: .atomic)
        snapshot = next
    }
    @discardableResult public func increment(_ id: UUID, now: Date = Date()) throws -> EpisodeUndo? {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == id }), snapshot.entries[i].episode < 1_000_000 else { return nil }
        var next = snapshot; let previous = next.entries[i]
        next.entries[i].episode += 1; next.entries[i].watchedAt = now; next.entries[i].updatedAt = now
        let token = EpisodeUndo(id: id, previous: previous, applied: next.entries[i]); try commit(next); return token
    }
    public func undo(_ token: EpisodeUndo) throws {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == token.id }),
              snapshot.entries[i].episode == token.applied.episode,
              snapshot.entries[i].watchedAt == token.applied.watchedAt else { return }
        var next = snapshot
        next.entries[i].episode = token.previous.episode
        next.entries[i].watchedAt = token.previous.watchedAt
        if next.entries[i].updatedAt == token.applied.updatedAt { next.entries[i].updatedAt = token.previous.updatedAt }
        try commit(next)
    }
}
public struct ImportRow: Identifiable, Equatable {
    public var id = UUID()
    public let original: String
    public var title: String
    public var episode: Int
    public var favorite: Bool
    public var recognized: Bool
    public var included = true
    public var entry: Entry { var e = Entry(title: title, episode: episode); e.favorite = favorite; return e }
}
public enum TextListParser {
    public static func parse(_ text: String) -> [ImportRow] {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return source.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            // Only a trailing, separated number is progress. Ambiguous lines keep their full title.
            let pattern = #"^(.*?)\s+(?:[—–\-:]\s*)?(\d{1,7})(?:\s*(?:серия|серии|серий|сер\.?))?$"#
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let number = Int(ns.substring(with: match.range(at: 2))), number <= 1_000_000 {
                let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return ImportRow(original: raw, title: title, episode: number, favorite: title.contains("⭐") || title.contains("★"), recognized: true) }
            }
            return ImportRow(original: raw, title: line, episode: 0, favorite: line.contains("⭐") || line.contains("★"), recognized: false)
        }
    }
}
public enum CoverPolicy {
    public static func permits(wifiOnly: Bool, connected: Bool, wifi: Bool) -> Bool { connected && (!wifiOnly || wifi) }
}
