import SwiftUI
import WebKit

/// Where to watch an episode inside the app: the found notice link, the connected AniVibe page or the user's own link.
enum WatchTarget {
    static func url(for e: Entry, episode: Int) -> URL? {
        if let notice = (e.releaseNotices ?? []).first(where: { $0.episode == episode }), let url = validWebURL(notice.url) { return url }
        if let source = (e.subscriptions ?? []).first(where: \.enabled), AnivibePageParser.canonicalURL(source.pageURL) != nil,
           var components = URLComponents(string: source.pageURL) {
            var items = [URLQueryItem(name: "episode", value: String(episode))]
            // Kodik tracks are chosen by the dub name, the first part of the source label.
            if source.optionID.hasPrefix("kodik"), let dub = source.label.components(separatedBy: " · ").first, !dub.isEmpty {
                items.append(URLQueryItem(name: "translation", value: dub)); items.append(URLQueryItem(name: "player", value: "kodik"))
            }
            components.queryItems = items; components.fragment = "player-section"
            return components.url
        }
        return validWebURL(e.watchURL)
    }
    static func available(_ e: Entry) -> Bool { url(for: e, episode: e.seasonEpisode + 1) != nil }
}

/// What the page's player reports: position, length, the episode it plays and the end of the episode.
@MainActor final class WatchModel: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var playerEpisode: Int?
    @Published var endedCount = 0
    @Published var loading = true
    func receive(_ body: Any) {
        guard let m = body as? [String: Any], let key = m["k"] as? String else { return }
        let value = m["v"]
        switch key {
        case "time", "kodik_player_time_update":
            if let t = (value as? NSNumber)?.doubleValue { position = t }
            if let d = (m["d"] as? NSNumber)?.doubleValue, d.isFinite, d > 0 { duration = d }
        case "kodik_player_duration_update":
            if let d = (value as? NSNumber)?.doubleValue, d > 0 { duration = d }
        case "ended", "kodik_player_video_ended":
            endedCount += 1
        case "kodik_player_current_episode":
            if let info = value as? [String: Any], let ep = (info["episode"] as? NSNumber)?.intValue ?? (info["episode"] as? String).flatMap({ Int($0) }) { playerEpisode = ep }
        default: break
        }
    }
}

/// The AniVibe page inside the app. Script in every frame (also the player's) listens to the video element and
/// Kodik's own messages; navigations of the main page to other sites and pop-up windows (ads) are blocked.
struct WatchWebView: UIViewRepresentable {
    let url: URL
    let model: WatchModel
    static let script = """
    (function(){
      if (window.__anipolka) return; window.__anipolka = true;
      function send(m){ try { window.webkit.messageHandlers.anipolka.postMessage(m); } catch(e){} }
      window.addEventListener('message', function(e){
        var d = e.data; if (typeof d === 'string') { try { d = JSON.parse(d); } catch(x) { return; } }
        if (d && d.key && String(d.key).indexOf('kodik_player') === 0) send({k: String(d.key), v: d.value});
      });
      function hook(v){
        if (v.__ap) return; v.__ap = true; var last = -1;
        v.addEventListener('timeupdate', function(){ var t = Math.floor(v.currentTime); if (t !== last && t % 5 === 0) { last = t; send({k:'time', v:v.currentTime, d:v.duration}); } });
        v.addEventListener('ended', function(){ send({k:'ended', d:v.duration}); });
      }
      setInterval(function(){ var vs = document.getElementsByTagName('video'); for (var i = 0; i < vs.length; i++) hook(vs[i]); }, 1000);
    })();
    """
    func makeCoordinator() -> Coordinator { Coordinator(model: model, host: url.host ?? "") }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: "anipolka")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false; view.backgroundColor = .black; view.scrollView.backgroundColor = .black
        view.load(URLRequest(url: url))
        context.coordinator.loaded = url
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != url { context.coordinator.loaded = url; view.load(URLRequest(url: url)) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "anipolka")
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let model: WatchModel
        let host: String
        var loaded: URL?
        init(model: WatchModel, host: String) { self.model = model; self.host = host }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            Task { @MainActor in self.model.receive(body) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Frames (players) load freely; the page itself stays on its site, so ad redirects do nothing.
            guard action.targetFrame?.isMainFrame == true, let target = action.request.url?.host else { decisionHandler(.allow); return }
            let base = host.split(separator: ".").suffix(2).joined(separator: ".")
            decisionHandler(target == host || target.hasSuffix("." + base) || target == base ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in self.model.loading = false } }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { Task { @MainActor in self.model.loading = false } }
    }
}

/// Built-in viewing: the right episode and dub; the end of the episode marks it watched,
/// closing in the middle saves «Где остановился» with the minute.
struct WatchView: View {
    let entryID: UUID
    @State var episode: Int
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model = WatchModel()
    @State private var markedEpisodes: Set<Int> = []
    @State private var banner: String?
    private var entry: Entry? { store.snapshot.entries.first { $0.id == entryID } }
    private var url: URL? { entry.flatMap { WatchTarget.url(for: $0, episode: episode) } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if let url { WatchWebView(url: url, model: model).ignoresSafeArea(edges: .bottom) }
                else { ContentUnavailableView("Нет страницы просмотра", systemImage: "play.slash", description: Text("Подключите источник AniVibe или добавьте ссылку в «Где смотрю».")) }
                if model.loading && url != nil { ProgressView().tint(.white).padding(.bottom, 80) }
                if let banner {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(banner).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Следующая") { next() }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .padding(14).shelfGlass(in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Серия \(model.playerEpisode ?? episode)").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { close() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Отметить серию просмотренной", systemImage: "checkmark.circle") { mark(model.playerEpisode ?? episode) }
                        Button("Следующая серия", systemImage: "forward.end") { next() }
                        if episode > 1 { Button("Предыдущая серия", systemImage: "backward.end") { episode -= 1; reset() } }
                        if let url { Button("Открыть в Safari", systemImage: "safari") { openURL(url) } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("watch-menu")
                }
            }
        }
        .onChange(of: model.endedCount) { _, _ in mark(model.playerEpisode ?? episode) }
        .onChange(of: model.position) { _, value in
            // Credits: an episode watched to its last minute counts as finished even if the video does not report the end.
            if model.duration > 300, value > model.duration - 75 { mark(model.playerEpisode ?? episode) }
        }
        .onChange(of: model.playerEpisode) { _, value in if let value { episode = value } }
    }

    private func mark(_ number: Int) {
        guard !markedEpisodes.contains(number), let e = entry else { return }
        markedEpisodes.insert(number)
        if number > e.seasonEpisode { _ = store.increment(id: e.id, by: number - e.seasonEpisode) }
        withAnimation(.snappy) { banner = "Серия \(number) отмечена" }
    }
    private func next() { episode = (model.playerEpisode ?? episode) + 1; reset() }
    private func reset() { model.position = 0; model.duration = 0; model.playerEpisode = nil; model.loading = true; withAnimation { banner = nil } }
    private func close() {
        let number = model.playerEpisode ?? episode
        if model.position >= 60, !markedEpisodes.contains(number), let e = entry {
            let seconds = Int(model.position)
            let time = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
            let absolute = number + (e.episodeOffset ?? 0)
            _ = store.change { s in
                if let i = s.entries.firstIndex(where: { $0.id == e.id }) { s.entries[i].addNote(EpisodeNote(episode: absolute, time: time, text: "Встроенный просмотр")) }
            }
        }
        dismiss()
    }
}
