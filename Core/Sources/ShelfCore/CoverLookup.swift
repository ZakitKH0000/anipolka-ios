import Foundation

enum AnimeCatalog: String, Codable, CaseIterable { case shikimori = "Shikimori", kitsu = "Kitsu" }

enum CoverImagePolicy {
    static func isPlaceholder(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        let path = url.path.removingPercentEncoding?.lowercased() ?? url.path.lowercased()
        // Shikimori returns HTTP 200 and a decodable JPEG for these error pictures.
        return path.contains("/assets/globals/missing_") || path == "/assets/globals/missing.jpg"
    }
    static func usableURL(_ address: String) -> URL? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: address), url.scheme?.lowercased() == "https",
              url.host != nil, !isPlaceholder(address) else { return nil }
        return url
    }
    static func acceptsResponse(status: Int, mimeType: String?, url: String) -> Bool {
        status == 200 && mimeType?.lowercased().hasPrefix("image/") == true && usableURL(url) != nil
    }
}

struct AnimeCandidate: Decodable, Identifiable {
    struct Poster: Decodable { let original: String; let preview: String }
    let id: Int
    let name: String
    let russian: String?
    let image: Poster
    let url: String
    let kind: String?
    let episodes: Int?
    let aired_on: String?
    var catalog: AnimeCatalog? = nil
    var aliases: [String]? = nil
    var shikimoriID: Int? { catalog == .kitsu ? nil : id }
    var title: String { russian.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    var posterURL: String { CoverImagePolicy.usableURL(absolute(image.original))?.absoluteString ?? "" }
    var previewURL: String { CoverImagePolicy.usableURL(absolute(image.preview))?.absoluteString ?? posterURL }
    var pageURL: String { absolute(url) }
    var names: [String] { [title,name] + (aliases ?? []) }
    var detail: String { [name, aired_on.map { String($0.prefix(4)) }, kind?.uppercased(), episodes.flatMap { $0 > 0 ? "\($0) серий в каталоге" : nil }].compactMap { $0 }.joined(separator: " · ") }
    func absolute(_ path: String) -> String {
        guard !path.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return "" }
        return URL(string:path,relativeTo:URL(string:"https://shikimori.io")!)?.absoluteURL.absoluteString ?? ""
    }
    func sameEdition(as other: AnimeCandidate) -> Bool {
        let ownNames = Set(names.map(TitleIdentity.normalized).filter { !$0.isEmpty })
        guard !ownNames.isDisjoint(with:other.names.map(TitleIdentity.normalized).filter { !$0.isEmpty }) else { return false }
        if let date = other.aired_on, !date.isEmpty {
            guard let own = aired_on, own.prefix(4) == date.prefix(4) else { return false }
        }
        if let kind, let otherKind = other.kind, kind.lowercased() != otherKind.lowercased() { return false }
        return true
    }
}

struct ShikimoriGraphQLResponse: Decodable {
    struct Failure: Decodable { let message: String }
    struct Payload: Decodable {
        struct Anime: Decodable {
            struct DateParts: Decodable { let year: Int?; let month: Int?; let day: Int? }
            struct Poster: Decodable { let originalUrl: String?; let mainUrl: String? }
            let id: String; let name: String; let russian: String?; let url: String
            var english: String? = nil; var japanese: String? = nil; var synonyms: [String]? = nil
            let kind: String?; let episodes: Int?; let airedOn: DateParts?; let poster: Poster?
            var candidate: AnimeCandidate? {
                guard let id = Int(id) else { return nil }
                let original = [poster?.originalUrl,poster?.mainUrl].compactMap { $0 }.first { CoverImagePolicy.usableURL($0) != nil } ?? ""
                let date = airedOn?.year.map { String(format:"%04d-%02d-%02d",$0,airedOn?.month ?? 1,airedOn?.day ?? 1) }
                let other = ([english,japanese].compactMap { $0 } + (synonyms ?? [])).filter { !$0.isEmpty }
                return AnimeCandidate(id:id,name:name,russian:russian,image:.init(original:original,preview:poster?.mainUrl ?? original),url:url,kind:kind,episodes:episodes,aired_on:date,aliases:other.isEmpty ? nil : other)
            }
        }
        let animes: [Anime]
    }
    let data: Payload?
    let errors: [Failure]?
    func candidates() throws -> [AnimeCandidate] {
        guard errors?.isEmpty != false, let data else { throw ShelfError.invalid("Каталог временно не вернул обложки.") }
        return data.animes.compactMap(\.candidate)
    }
}

struct ResolvedCover {
    let candidate: AnimeCandidate?
    let url: String
    let data: Data
    let imageCatalog: AnimeCatalog?
}
enum CoverResolution { case found(ResolvedCover), notFound(needsChoice: Bool) }

/// Dependencies are injected so failures, cancellation and cross-catalog identity can be tested offline.
@MainActor enum AutomaticCoverLookup {
    typealias Search = (String, AnimeCatalog) async throws -> [AnimeCandidate]
    typealias Lookup = (Int) async throws -> AnimeCandidate?
    typealias Download = (String) async throws -> Data

    static func resolve(entry: Entry, search: Search, lookup: Lookup, download: Download) async throws -> CoverResolution {
        var attempted = Set<String>()
        func image(_ address: String) async throws -> Data? {
            try Task.checkCancellation()
            guard CoverImagePolicy.usableURL(address) != nil, attempted.insert(address).inserted else { return nil }
            do {
                let data = try await download(address); try Task.checkCancellation()
                return data.isEmpty ? nil : data
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                return nil
            }
        }
        if let data = try await image(entry.coverURL) {
            return .found(ResolvedCover(candidate:nil,url:entry.coverURL,data:data,imageCatalog:nil))
        }
        var identity: AnimeCandidate?
        var choices = false
        let query = TitleIdentity.query(entry.originalTitle.isEmpty ? entry.title : entry.originalTitle)
        if let id = entry.sourceID {
            // Keep the selected catalogue ID even when only its image comes from Kitsu.
            if !entry.originalTitle.isEmpty {
                identity = AnimeCandidate(id:id,name:entry.originalTitle,russian:nil,image:.init(original:"",preview:""),url:entry.sourceURL,kind:nil,episodes:nil,aired_on:nil)
            }
            do { if let found = try await lookup(id), found.shikimoriID == id { identity = found } }
            catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
            // Without a confirmed name a fallback search by the user's own title could pick
            // another work and replace the selected ID; retry later instead.
            guard identity != nil else { try Task.checkCancellation(); return .notFound(needsChoice:false) }
        } else {
            do {
                let candidates = try await search(query,.shikimori)
                choices = !candidates.isEmpty
                if let index = TitleIdentity.uniqueExactMatch(query:query,candidates:candidates.map(\.names)) { identity = candidates[index] }
            } catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
        }
        if let identity, let data = try await image(identity.posterURL) {
            return .found(ResolvedCover(candidate:identity,url:identity.posterURL,data:data,imageCatalog:.shikimori))
        }
        // A found title is not proof that its poster exists. Continue after empty images,
        // known placeholders, HTTP failures and invalid image data.
        let fallbackQuery = identity?.name ?? query
        do {
            let candidates = try await search(fallbackQuery,.kitsu)
            choices = choices || !candidates.isEmpty
            let matching = candidates.filter { candidate in
                guard let identity else { return true }
                return candidate.sameEdition(as:identity)
            }
            if let index = TitleIdentity.uniqueExactMatch(query:fallbackQuery,candidates:matching.map(\.names)) {
                let candidate = matching[index]
                if let data = try await image(candidate.posterURL) {
                    return .found(ResolvedCover(candidate:identity ?? candidate,url:candidate.posterURL,data:data,imageCatalog:.kitsu))
                }
            }
        } catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
        try Task.checkCancellation()
        return .notFound(needsChoice:identity == nil && choices)
    }
}

extension Snapshot {
    @discardableResult mutating func applyResolvedCover(_ cover: ResolvedCover, to expected: Entry) -> Bool {
        guard CoverImagePolicy.usableURL(cover.url) != nil, !cover.data.isEmpty, cover.data.count <= 3_000_000,
              let i = entries.firstIndex(where: { $0.id == expected.id }),
              entries[i].title == expected.title, entries[i].coverURL == expected.coverURL,
              entries[i].coverData == expected.coverData, entries[i].sourceID == expected.sourceID,
              entries[i].originalTitle == expected.originalTitle, entries[i].coverLookupDisabled != true else { return false }
        entries[i].coverURL = cover.url; entries[i].coverData = cover.data
        // A Kitsu result never replaces an already selected Shikimori work.
        if let candidate = cover.candidate, candidate.shikimoriID != nil || expected.sourceID == nil {
            entries[i].sourceID = candidate.shikimoriID; entries[i].sourceURL = candidate.pageURL
            entries[i].originalTitle = candidate.name
            entries[i].learnNames(candidate.names)
        }
        let origin = cover.imageCatalog.map { " · \($0.rawValue)" } ?? ""
        entries[i].coverDiscovery = CoverDiscovery(query:expected.title,message:"Обложка найдена и сохранена\(origin)",needsChoice:false)
        return true
    }
    /// Remove only recognisable catalogue error images; never touch a user's own photo.
    @discardableResult mutating func removePlaceholderCovers() -> Bool {
        var changed = false
        for i in entries.indices where CoverImagePolicy.isPlaceholder(entries[i].coverURL) {
            entries[i].coverData = nil; entries[i].coverURL = ""; entries[i].coverDiscovery = nil
            changed = true
        }
        return changed
    }
}
