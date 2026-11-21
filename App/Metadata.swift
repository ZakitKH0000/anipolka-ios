import Foundation
import SwiftUI
import Network
import UIKit
import ImageIO

@MainActor final class NetworkService: ObservableObject {
    @Published var connected = false
    @Published var wifi = false
    @Published var wifiOnly = false { didSet { if oldValue != wifiOnly { imageSession.invalidateAndCancel(); imageSession = Self.makeSession(wifiOnly: wifiOnly) } } }
    private let monitor = NWPathMonitor()
    private var imageSession = NetworkService.makeSession(wifiOnly: false)
    private var nextRequest = Date.distantPast
    private var cooldowns: [String:Date] = [:]
    private var nextSourceRequest = Date.distantPast
    var canLoadCovers: Bool { CoverPolicy.permits(wifiOnly: wifiOnly, connected: connected, wifi: wifi) }
    var revision: String { "\(connected)-\(wifi)-\(wifiOnly)" }
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.connected = path.status == .satisfied; self?.wifi = path.usesInterfaceType(.wifi)
                if self?.canLoadCovers == false { self?.imageSession.invalidateAndCancel(); self?.imageSession = Self.makeSession(wifiOnly: self?.wifiOnly ?? false) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "AniPolka.network"))
    }
    deinit { monitor.cancel() }
    private static func makeSession(wifiOnly: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = !wifiOnly
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config)
    }
    private func metadata(_ url: URL, body: Data? = nil) async throws -> Data {
        let host = url.host ?? ""
        do { let data = try await metadataRequest(url, body: body); SourceHealth.shared.record(host: host, error: nil); return data }
        catch is CancellationError { throw CancellationError() }
        catch { SourceHealth.shared.record(host: host, error: error); throw error }
    }
    private func metadataRequest(_ url: URL, body: Data?) async throws -> Data {
        let host = url.host ?? ""
        guard host == "graphql.anilist.co" else { return try await metadataCall(url, body: body, timeout: 20) }
        do { return try await metadataCall(url, body: body, timeout: 8) }
        catch let error as URLError where ([.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .secureConnectionFailed] as [URLError.Code]).contains(error.code) {
            throw ShelfError.invalid("AniList недоступен из этой сети (часто открывается только через VPN). Время серий берётся из Shikimori.")
        }
    }
    private func metadataCall(_ url: URL, body: Data?, timeout: TimeInterval) async throws -> Data {
        let host = url.host ?? ""
        guard Date() >= (cooldowns[host] ?? .distantPast) else { throw ShelfError.invalid("Каталог просит подождать. Повторите поиск через минуту.") }
        let wait = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(wait + 1.0)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        request.setValue("AniPolka/1.1 (personal iOS collection)", forHTTPHeaderField: "User-Agent")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        request.setValue(url.host == "kitsu.io" ? "application/vnd.api+json" : "application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 { cooldowns[host] = Date().addingTimeInterval(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60); throw ShelfError.invalid("Слишком много запросов. Повторите через минуту.") }
        guard http.statusCode == 200 else { throw ShelfError.invalid("\(host) ответил кодом \(http.statusCode)" + (String(data: data.prefix(160), encoding: .utf8).map { ": " + $0 } ?? "")) }
        return data
    }
    func search(_ text: String, catalog: AnimeCatalog = .shikimori) async throws -> [AnimeCandidate] {
        if catalog == .kitsu { return try await searchKitsu(text) }
        do { return try await shikimoriGraphQL(filter:"search: $value",value:text) }
        catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
        // Legacy REST remains useful for title identity, but its missing-image URLs
        // are filtered by AnimeCandidate and never passed off as actual posters.
        var components = URLComponents(string: "https://shikimori.io/api/animes")!
        components.queryItems = [URLQueryItem(name: "search", value: text), .init(name:"limit",value:"30"), .init(name:"censored",value:"true")]
        return try JSONDecoder().decode([AnimeCandidate].self, from: await metadata(components.url!))
    }
    private func shikimoriGraphQL(filter: String,value: String) async throws -> [AnimeCandidate] {
        let query = "query($value: String!) { animes(\(filter), limit: 30, censored: true) { id name russian english japanese synonyms url kind episodes airedOn { year month day } poster { originalUrl mainUrl } } }"
        let body = try JSONSerialization.data(withJSONObject:["query":query,"variables":["value":value]])
        let data = try await metadata(URL(string:"https://shikimori.io/api/graphql")!,body:body)
        return try JSONDecoder().decode(ShikimoriGraphQLResponse.self,from:data).candidates()
    }
    func shikimoriCandidate(id: Int) async throws -> AnimeCandidate? {
        do { return try await shikimoriGraphQL(filter:"ids: $value",value:String(id)).first { $0.id == id } }
        catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
        let data = try await metadata(URL(string:"https://shikimori.io/api/animes/\(id)")!)
        let candidate = try JSONDecoder().decode(AnimeCandidate.self,from:data)
        return candidate.id == id ? candidate : nil
    }
    private func searchKitsu(_ text: String) async throws -> [AnimeCandidate] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable {
                    struct Poster: Decodable { let large: String?; let original: String?; let small: String? }
                    let canonicalTitle: String; let titles: [String:String?]; let slug: String
                    let posterImage: Poster?; let subtype: String?; let episodeCount: Int?; let startDate: String?
                }
                let id: String; let attributes: Attributes
            }
            let data: [Item]
        }
        var components = URLComponents(string:"https://kitsu.io/api/edge/anime")!
        components.queryItems = [.init(name:"filter[text]",value:text),.init(name:"page[limit]",value:"20")]
        let response = try JSONDecoder().decode(Response.self,from:await metadata(components.url!))
        return response.data.compactMap { item in
            guard let id = Int(item.id) else { return nil }; let a = item.attributes
            let poster = [a.posterImage?.large,a.posterImage?.original,a.posterImage?.small].compactMap { $0 }.first { CoverImagePolicy.usableURL($0) != nil } ?? ""
            let russian = a.titles["ru_ru"].flatMap { $0 } ?? a.titles["ru"].flatMap { $0 }
            return AnimeCandidate(id:id,name:a.canonicalTitle,russian:russian,image:.init(original:poster,preview:a.posterImage?.small ?? poster),url:"https://kitsu.app/anime/\(a.slug)",kind:a.subtype,episodes:a.episodeCount,aired_on:a.startDate,catalog:.kitsu,aliases:a.titles.values.compactMap { $0 })
        }
    }
    func automaticCover(_ entry: Entry) async throws -> CoverResolution {
        try await AutomaticCoverLookup.resolve(entry:entry,
            search:{ text,catalog in try await self.search(text,catalog:catalog) },
            lookup:{ id in try await self.shikimoriCandidate(id:id) },
            download:{ address in try await self.image(address) })
    }
    /// Public sitemap files of AniVibe; the site's search is closed to automated requests by robots.txt.
    func anivibeSitemap(_ url: URL) async throws -> String {
        guard url.scheme == "https", AnivibeMirror.isKnown(url.host), url.path.hasSuffix(".xml") else { throw URLError(.badURL) }
        let url = AnivibeMirror.live(url)
        let delay = max(0,nextSourceRequest.timeIntervalSinceNow)
        nextSourceRequest = Date().addingTimeInterval(delay + 1.2)
        if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
        var request = URLRequest(url:url); request.timeoutInterval = 30
        request.setValue("AniPolka/1.2 (personal episode tracker)",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, AnivibeMirror.isKnown(http.url?.host), data.count <= 30_000_000,
              let xml = String(data:data,encoding:.utf8) else { throw ShelfError.invalid("Список страниц AniVibe сейчас недоступен. Вставьте ссылку вручную.") }
        return xml
    }
    func sourcePage(_ url: URL) async throws -> String {
        do { let html = try await sourcePageRequest(url); SourceHealth.shared.record(host: "anivibe.pro", error: nil); return html }
        catch is CancellationError { throw CancellationError() }
        catch { SourceHealth.shared.record(host: "anivibe.pro", error: error); throw error }
    }
    private func sourcePageRequest(_ url: URL) async throws -> String {
        let delay = max(0,nextSourceRequest.timeIntervalSinceNow)
        nextSourceRequest = Date().addingTimeInterval(delay + 1.2)
        if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
        var request = URLRequest(url:AnivibeMirror.live(url)); request.timeoutInterval = 20
        request.setValue("AniPolka/1.1 (personal episode tracker)",forHTTPHeaderField:"User-Agent")
        let (bytes,response) = try await URLSession.shared.bytes(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, AnivibePageParser.canonicalURL(final.absoluteString) != nil else { throw ShelfError.invalid("AniVibe временно недоступен или требует входа. Проверка не изменила данные источника.") }
        var data = Data()
        for try await byte in bytes { if data.count >= 8_000_000 { throw ShelfError.invalid("Страница источника слишком большая.") }; data.append(byte) }
        try Task.checkCancellation()
        guard let html = String(data:data,encoding:.utf8) else { throw ShelfError.invalid("Не удалось прочитать страницу источника.") }; return html
    }
    /// Exact next episodes from AniList (Shikimori ids are MyAnimeList ids).
    func aniList(_ ids: [Int]) async throws -> [Int: AniList.Next] {
        guard !ids.isEmpty else { return [:] }
        return try AniList.parse(await metadata(URL(string:"https://graphql.anilist.co")!,body:AniList.query(ids)))
    }
    /// Public preview of a Telegram channel; t.me is often reachable only through a VPN.
    func telegramPage(_ url: URL) async throws -> String {
        guard TelegramChannel.canonicalURL(url.absoluteString) != nil else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("AniPolka/1.4 (personal episode tracker)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "t.me", data.count <= 8_000_000,
                  let html = String(data: data, encoding: .utf8), html.contains("tgme_widget_message") else {
                throw ShelfError.invalid("Канал не открылся как публичный: проверьте название. Закрытые каналы не поддерживаются.")
            }
            SourceHealth.shared.record(host: "t.me", error: nil)
            return html
        } catch let error as URLError where ([.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .secureConnectionFailed] as [URLError.Code]).contains(error.code) {
            let friendly = ShelfError.invalid("Telegram недоступен из этой сети — включите VPN и проверьте снова.")
            SourceHealth.shared.record(host: "t.me", error: friendly); throw friendly
        } catch is CancellationError { throw CancellationError() }
        catch { SourceHealth.shared.record(host: "t.me", error: error); throw error }
    }
    /// Bangumi subject whose name is exactly the native title.
    func bangumiSubject(native: String) async throws -> Int? {
        guard let url = Bangumi.searchURL(native) else { return nil }
        do { return Bangumi.pickSubject(try await metadata(url), native: native) }
        catch ShelfError.invalid(let text) where text.contains("ответил кодом 404") { return nil }
    }
    /// Episodes of a Bangumi subject: aired by today and the next one with its date.
    func bangumiEpisodes(_ id: Int) async throws -> BangumiInfo {
        var data = try await metadata(Bangumi.episodesURL(id))
        if let total = Bangumi.total(data), total > 200 { data = try await metadata(Bangumi.episodesURL(id, offset: total - 150)) }
        let parsed = try Bangumi.parseEpisodes(data, today: Bangumi.today())
        return BangumiInfo(id: id, checkedAt: Date(), aired: parsed.aired, nextEpisode: parsed.next, nextDate: parsed.nextDate)
    }
    /// AniLibria's weekly dub schedule.
    func libriaSchedule() async throws -> [Int: LibriaInfo] { try AniLibria.parseSchedule(await metadata(AniLibria.scheduleURL)) }
    /// The same spaced, rate-limited catalogue request for the catalogue screens in other files.
    func metadataPublic(_ url: URL, body: Data? = nil) async throws -> Data { try await metadata(url, body: body) }
    /// Broadcast data for up to 50 titles in one request; only catalogue IDs are sent.
    func airing(ids: [Int]) async throws -> [Int: AiringInfo] {
        guard !ids.isEmpty else { return [:] }
        return try Airing.parse(await metadata(URL(string:"https://shikimori.io/api/graphql")!,body:Airing.query(ids)))
    }
    /// Every season, film and special of one franchise.
    func franchise(_ key: String, previous: FranchiseInfo?) async throws -> FranchiseInfo {
        try Franchise.parse(await metadata(URL(string:"https://shikimori.io/api/graphql")!,body:Franchise.query(key)),key:key,previous:previous)
    }
    func alternatives(id: Int) async throws -> [String] {
        struct Shot: Decodable { let original: String }
        let data = try await metadata(URL(string: "https://shikimori.io/api/animes/\(id)/screenshots")!)
        return try JSONDecoder().decode([Shot].self, from: data).prefix(16).map { URL(string: $0.original, relativeTo: URL(string: "https://shikimori.io")!)!.absoluteURL.absoluteString }
    }
    func image(_ address: String) async throws -> Data {
        guard canLoadCovers else { throw ShelfError.invalid("Загрузка обложек ожидает Wi-Fi или подключения к сети.") }
        guard let url = CoverImagePolicy.usableURL(address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.allowsCellularAccess = !wifiOnly
        request.setValue("AniPolka/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await imageSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              CoverImagePolicy.acceptsResponse(status:http.statusCode,mimeType:http.mimeType,url:http.url?.absoluteString ?? "") else { throw URLError(.badServerResponse) }
        var data = Data()
        // Bound streamed downloads before decoding image data.
        for try await byte in bytes { if data.count >= 12_000_000 { throw ShelfError.invalid("Изображение слишком большое.") }; data.append(byte) }
        try Task.checkCancellation()
        guard canLoadCovers, let image = Self.normalized(data) else { throw ShelfError.invalid("Обложка недоступна или повреждена.") }
        return image
    }
    static func normalized(_ data: Data) -> Data? {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:1200, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumb).jpegData(compressionQuality: 0.82)
    }
}

struct CoverView: View {
    let data: Data?
    let url: String
    var entryID: UUID? = nil
    @EnvironmentObject private var network: NetworkService
    @EnvironmentObject private var store: ShelfStore
    @State private var downloaded: Data?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [.blue.opacity(0.3), .indigo.opacity(0.18)], startPoint:.topLeading, endPoint:.bottomTrailing)
                if !CoverImagePolicy.isPlaceholder(url), let bytes = data ?? downloaded, let uiImage = UIImage(data: bytes) {
                    Image(uiImage: uiImage).resizable().scaledToFill().frame(width:geo.size.width,height:geo.size.height).clipped()
                } else {
                    Image(systemName: "sparkles.tv").font(.system(size:32,weight:.light)).foregroundStyle(.secondary)
                }
            }
        }
        .clipped().accessibilityHidden(true)
        .task(id: url + network.revision) {
            downloaded = nil
            guard data == nil, CoverImagePolicy.usableURL(url) != nil, network.canLoadCovers else { return }
            if let result = try? await network.image(url), !Task.isCancelled {
                downloaded = result
                if let id = entryID { store.cacheCover(id:id,url:url,data:result) }
            }
        }
    }
}
