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
        guard Date() >= (cooldowns[host] ?? .distantPast) else { throw ShelfError.invalid("Каталог просит подождать. Повторите поиск через минуту.") }
        let wait = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(wait + 1.0)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("AniPolka/1.1 (personal iOS collection)", forHTTPHeaderField: "User-Agent")
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        if url.host == "kitsu.io" { request.setValue("application/vnd.api+json",forHTTPHeaderField:"Accept") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 { cooldowns[host] = Date().addingTimeInterval(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60); throw ShelfError.invalid("Слишком много запросов. Повторите через минуту.") }
        guard http.statusCode == 200 else { throw ShelfError.invalid("Каталог недоступен (\(http.statusCode)). Можно добавить запись вручную.") }
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
        guard url.scheme == "https", url.host == "anivibe.pro", url.path.hasSuffix(".xml") else { throw URLError(.badURL) }
        let delay = max(0,nextSourceRequest.timeIntervalSinceNow)
        nextSourceRequest = Date().addingTimeInterval(delay + 1.2)
        if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
        var request = URLRequest(url:url); request.timeoutInterval = 30
        request.setValue("AniPolka/1.2 (personal episode tracker)",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "anivibe.pro", data.count <= 30_000_000,
              let xml = String(data:data,encoding:.utf8) else { throw ShelfError.invalid("Список страниц AniVibe сейчас недоступен. Вставьте ссылку вручную.") }
        return xml
    }
    func sourcePage(_ url: URL) async throws -> String {
        let delay = max(0,nextSourceRequest.timeIntervalSinceNow)
        nextSourceRequest = Date().addingTimeInterval(delay + 1.2)
        if delay > 0 { try await Task.sleep(for:.seconds(delay)) }
        var request = URLRequest(url:url); request.timeoutInterval = 20
        request.setValue("AniPolka/1.1 (personal episode tracker)",forHTTPHeaderField:"User-Agent")
        let (bytes,response) = try await URLSession.shared.bytes(for:request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let final = http.url, AnivibePageParser.canonicalURL(final.absoluteString) != nil else { throw ShelfError.invalid("AniVibe временно недоступен или требует входа. Проверка не изменила данные источника.") }
        var data = Data()
        for try await byte in bytes { if data.count >= 8_000_000 { throw ShelfError.invalid("Страница источника слишком большая.") }; data.append(byte) }
        try Task.checkCancellation()
        guard let html = String(data:data,encoding:.utf8) else { throw ShelfError.invalid("Не удалось прочитать страницу источника.") }; return html
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
