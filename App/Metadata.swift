import Foundation
import SwiftUI
import Network
import UIKit
import ImageIO

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
    var title: String { russian.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    var posterURL: String { absolute(image.original) }
    var previewURL: String { absolute(image.preview) }
    var pageURL: String { absolute(url) }
    var detail: String { [name, aired_on.map { String($0.prefix(4)) }, kind?.uppercased(), episodes.flatMap { $0 > 0 ? "\($0) серий в каталоге" : nil }].compactMap { $0 }.joined(separator: " · ") }
    func absolute(_ path: String) -> String { URL(string: path, relativeTo: URL(string: "https://shikimori.io")!)?.absoluteURL.absoluteString ?? "" }
}
@MainActor final class NetworkService: ObservableObject {
    @Published var connected = false
    @Published var wifi = false
    @Published var wifiOnly = false { didSet { if oldValue != wifiOnly { imageSession.invalidateAndCancel(); imageSession = Self.makeSession(wifiOnly: wifiOnly) } } }
    private let monitor = NWPathMonitor()
    private var imageSession = NetworkService.makeSession(wifiOnly: false)
    private var nextRequest = Date.distantPast
    private var cooldown = Date.distantPast
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
    private func metadata(_ url: URL) async throws -> Data {
        guard Date() >= cooldown else { throw ShelfError.invalid("Каталог просит подождать. Повторите поиск через минуту.") }
        let wait = max(0, nextRequest.timeIntervalSinceNow)
        nextRequest = Date().addingTimeInterval(wait + 1.0)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("AniPolka/1.0 (personal iOS collection)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429 { cooldown = Date().addingTimeInterval(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60); throw ShelfError.invalid("Слишком много запросов. Повторите через минуту.") }
        guard http.statusCode == 200 else { throw ShelfError.invalid("Каталог недоступен (\(http.statusCode)). Можно добавить запись вручную.") }
        return data
    }
    func search(_ text: String) async throws -> [AnimeCandidate] {
        var components = URLComponents(string: "https://shikimori.io/api/animes")!
        components.queryItems = [URLQueryItem(name: "search", value: text), .init(name:"limit",value:"30"), .init(name:"censored",value:"true")]
        return try JSONDecoder().decode([AnimeCandidate].self, from: await metadata(components.url!))
    }
    func alternatives(id: Int) async throws -> [String] {
        struct Shot: Decodable { let original: String }
        let data = try await metadata(URL(string: "https://shikimori.io/api/animes/\(id)/screenshots")!)
        return try JSONDecoder().decode([Shot].self, from: data).prefix(16).map { URL(string: $0.original, relativeTo: URL(string: "https://shikimori.io")!)!.absoluteURL.absoluteString }
    }
    func image(_ address: String) async throws -> Data {
        guard canLoadCovers else { throw ShelfError.invalid("Загрузка обложек ожидает Wi-Fi или подключения к сети.") }
        guard let url = URL(string: address), url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.allowsCellularAccess = !wifiOnly
        request.setValue("AniPolka/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await imageSession.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
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
                if let bytes = data ?? downloaded, let uiImage = UIImage(data: bytes) {
                    Image(uiImage: uiImage).resizable().scaledToFill().frame(width:geo.size.width,height:geo.size.height).clipped()
                } else {
                    Image(systemName: "sparkles.tv").font(.system(size:32,weight:.light)).foregroundStyle(.secondary)
                }
            }
        }
        .clipped().accessibilityHidden(true)
        .task(id: url + network.revision) {
            downloaded = nil
            guard data == nil, !url.isEmpty, network.canLoadCovers else { return }
            if let result = try? await network.image(url), !Task.isCancelled {
                downloaded = result
                if let id = entryID { store.cacheCover(id:id,url:url,data:result) }
            }
        }
    }
}
