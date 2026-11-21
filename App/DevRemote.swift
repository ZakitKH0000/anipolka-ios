#if DEV_REMOTE
import SwiftUI
import UIKit
import Network

/// Special test build only (compiled with DEV_REMOTE): a small HTTP server on the home Wi-Fi so the
/// computer can read the screen, tap elements by their accessibility label and check the collection.
/// It starts only from Settings, needs the token shown there and stops when the app leaves the screen.
@MainActor final class DevRemote: ObservableObject {
    static let shared = DevRemote()
    static let port: UInt16 = 8765
    @Published private(set) var running = false
    @Published private(set) var address = ""
    @Published private(set) var lastCommand = ""
    let token: String
    private var listener: NWListener?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "devRemoteToken") { token = saved }
        else { token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased(); UserDefaults.standard.set(token, forKey: "devRemoteToken") }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            l.service = NWListener.Service(name: "AniPolka", type: "_anipolka._tcp")
            l.newConnectionHandler = { connection in Task { @MainActor in DevRemote.shared.accept(connection) } }
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready: DevRemote.shared.running = true
                    case .failed(let error): DevRemote.shared.running = false; DevRemote.shared.address = "Ошибка: \(error.localizedDescription)"
                    case .cancelled: DevRemote.shared.running = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
            address = (Self.wifiAddress() ?? "нет Wi-Fi") + ":\(Self.port)"
        } catch { address = "Ошибка: \(error.localizedDescription)" }
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    // MARK: HTTP

    private struct Request {
        var method: String, path: String, query: [String: String], headers: [String: String], body: Data
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)), let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ").map(String.init) ?? []
            guard first.count >= 2 else { return nil }
            method = first[0]
            let target = URLComponents(string: "http://phone" + first[1])
            path = target?.path ?? "/"
            query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            var h: [String: String] = [:]
            for line in lines.dropFirst() { if let i = line.firstIndex(of: ":") { h[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            headers = h
            let length = Int(h["content-length"] ?? "0") ?? 0
            let rest = data[end.upperBound...]
            guard rest.count >= length else { return nil }
            body = Data(rest.prefix(length))
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            Task { @MainActor in
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Request(buffer) {
                    let (status, type, body) = await DevRemote.shared.handle(request)
                    DevRemote.shared.send(connection, status: status, type: type, body: body)
                } else if done || error != nil || buffer.count > 160_000_000 {
                    connection.cancel()
                } else {
                    DevRemote.shared.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, type: String, body: Data) {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if type.hasPrefix("text") || type.hasPrefix("application/json") { head = head.replacingOccurrences(of: "Content-Type: \(type)", with: "Content-Type: \(type); charset=utf-8") }
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func json(_ object: [String: Any], status: Int = 200) -> (Int, String, Data) {
        (status, "application/json", (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8))
    }

    private func handle(_ r: Request) async -> (Int, String, Data) {
        guard (r.headers["x-token"] ?? r.query["token"]) == token else { return json(["error": "Неверный токен"], status: 401) }
        lastCommand = r.method + " " + r.path
        let store = ShelfStore.shared
        switch (r.method, r.path) {
        case ("GET", "/ping"):
            return json(["ok": true, "app": "AniPolka", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
        case ("GET", "/state"):
            let s = store.snapshot
            return json([
                "entries": s.entries.map { e -> [String: Any] in
                    var item: [String: Any] = ["id": e.id.uuidString, "title": e.title, "episode": e.episode, "status": e.status.rawValue,
                                               "unread": (e.releaseNotices ?? []).filter { !$0.read }.count, "notices": (e.releaseNotices ?? []).count,
                                               "sources": (e.subscriptions ?? []).count, "favorite": e.favorite, "hasCover": e.coverData != nil]
                    if let id = e.sourceID { item["shikimori"] = id }
                    if let a = e.airing { item["airing"] = Airing.progressText(a); if let at = Airing.upcoming(e) { item["next"] = Airing.moment(at) } }
                    if let hint = Airing.sequelSuggestion(e, in: s) { item["sequel"] = hint.title }
                    return item
                },
                "unread": NoticeInbox.unread(s), "count": s.entries.count, "error": store.error ?? "", "undo": store.undoToken != nil,
            ])
        case ("GET", "/screenshot"):
            guard let window = Self.keyWindow else { return json(["error": "Нет окна"], status: 500) }
            let format = UIGraphicsImageRendererFormat(); format.scale = min(2, window.traitCollection.displayScale)
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            if r.query["format"] == "png" { return (200, "image/png", image.pngData() ?? Data()) }
            return (200, "image/jpeg", image.jpegData(compressionQuality: 0.75) ?? Data())
        case ("GET", "/tree"):
            return json(["elements": Self.elements().enumerated().map { i, e in e.describe(index: i) }])
        case ("POST", "/tap"):
            let wanted = r.query["label"] ?? String(data: r.body, encoding: .utf8) ?? ""
            let matches = Self.elements().filter { $0.matches(wanted) }
            let index = Int(r.query["index"] ?? "0") ?? 0
            guard matches.indices.contains(index) else { return json(["error": "Не найдено: \(wanted)", "found": matches.count], status: 404) }
            let done = matches[index].activate()
            try? await Task.sleep(for: .milliseconds(450))
            return json(["ok": done, "tapped": matches[index].label, "found": matches.count])
        case ("POST", "/scroll"):
            guard let scroll = Self.mainScrollView() else { return json(["error": "Нет прокрутки"], status: 404) }
            let up = r.query["dir"] == "up"
            let step = scroll.bounds.height * 0.7
            let maxY = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let y = up ? max(-scroll.adjustedContentInset.top, scroll.contentOffset.y - step) : min(maxY, scroll.contentOffset.y + step)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
            try? await Task.sleep(for: .milliseconds(450))
            return json(["ok": true, "offset": y])
        case ("POST", "/type"):
            let text = r.query["text"] ?? String(data: r.body, encoding: .utf8) ?? ""
            guard let input = UIResponder.currentFirst as? UIKeyInput else { return json(["error": "Нет активного поля ввода"], status: 404) }
            if text == "\n" || r.query["key"] == "return" { input.insertText("\n") } else { input.insertText(text) }
            return json(["ok": true])
        case ("POST", "/hide-keyboard"):
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return json(["ok": true])
        case ("POST", "/back"):
            return json(["ok": Self.goBack()])
        case ("POST", "/open"):
            guard let raw = r.query["url"], let url = URL(string: raw), url.scheme == "anipolka" || url.scheme == "https" else { return json(["error": "Нужен адрес anipolka:// или https://"], status: 400) }
            _ = await UIApplication.shared.open(url)
            return json(["ok": true])
        case ("GET", "/backup"):
            guard let data = try? store.snapshot.encoded() else { return json(["error": "Нет данных"], status: 500) }
            return (200, "application/json", data)
        case ("POST", "/restore"):
            // Replaces the whole collection; the computer keeps the copy it sent. Only with confirm=yes.
            guard r.query["confirm"] == "yes" else { return json(["error": "Добавьте confirm=yes"], status: 400) }
            do {
                let copy = try Snapshot.decode(r.body)
                return json(["ok": store.change { $0 = copy }, "count": copy.entries.count])
            } catch { return json(["error": error.localizedDescription], status: 400) }
        default:
            return json(["error": "Неизвестная команда", "commands": ["GET /ping", "GET /state", "GET /screenshot", "GET /tree", "POST /tap?label=", "POST /scroll?dir=down|up", "POST /type?text=", "POST /hide-keyboard", "POST /back", "POST /open?url=", "GET /backup", "POST /restore?confirm=yes"]], status: 404)
        }
    }

    // MARK: Screen

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    private struct Element {
        let object: NSObject
        let label: String
        let value: String
        let identifier: String
        let frame: CGRect
        let button: Bool
        func matches(_ text: String) -> Bool {
            let t = text.lowercased()
            return !t.isEmpty && (label.lowercased().contains(t) || identifier.lowercased() == t)
        }
        func describe(index: Int) -> [String: Any] {
            var d: [String: Any] = ["i": index, "label": label, "frame": [Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)]]
            if !value.isEmpty { d["value"] = value }
            if !identifier.isEmpty { d["id"] = identifier }
            if button { d["button"] = true }
            return d
        }
        func activate() -> Bool {
            if object.accessibilityActivate() { return true }
            if let control = object as? UIControl { control.sendActions(for: .touchUpInside); return true }
            return false
        }
    }

    private static func elements() -> [Element] {
        guard let window = keyWindow else { return [] }
        var result: [Element] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.02 { return }
            if object.isAccessibilityElement {
                let frame = object.accessibilityFrame
                if frame.intersects(window.bounds), frame.width > 1 {
                    result.append(Element(object: object, label: object.accessibilityLabel ?? "", value: object.accessibilityValue ?? "",
                                          identifier: (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "",
                                          frame: frame, button: object.accessibilityTraits.contains(.button)))
                }
            }
            if let list = object.accessibilityElements as? [NSObject] { for child in list { visit(child, depth: depth + 1) } }
            else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 { for i in 0..<min(count, 2000) { if let child = object.accessibilityElement(at: i) as? NSObject { visit(child, depth: depth + 1) } } }
            }
            if let view = object as? UIView { for sub in view.subviews { visit(sub, depth: depth + 1) } }
        }
        visit(window, depth: 0)
        // Sheets and alerts above the main screen come first in iOS's own order; keep reading order top to bottom.
        return result.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    private static func mainScrollView() -> UIScrollView? {
        guard let window = keyWindow else { return nil }
        var best: UIScrollView?
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.02 { return }
            if let s = view as? UIScrollView, s.isScrollEnabled, s.contentSize.height > s.bounds.height + 1,
               s.bounds.width > window.bounds.width * 0.6, s.convert(s.bounds, to: window).intersects(window.bounds) {
                if best == nil || s.bounds.height * s.bounds.width >= best!.bounds.height * best!.bounds.width { best = s }
            }
            view.subviews.forEach(visit)
        }
        // The topmost presented sheet wins over the screen under it.
        if let top = topController(), let root = top.view { visit(root) }
        if best == nil { visit(window) }
        return best
    }

    private static func topController() -> UIViewController? {
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private static func goBack() -> Bool {
        guard let root = keyWindow?.rootViewController else { return false }
        if let top = topController(), top !== root {
            if let nav = navigation(in: top), nav.viewControllers.count > 1 { nav.popViewController(animated: true); return true }
            top.dismiss(animated: true); return true
        }
        if let nav = navigation(in: root), nav.viewControllers.count > 1 { nav.popViewController(animated: true); return true }
        return false
    }

    /// The navigation stack that is on screen: inside the selected tab when there is a tab bar.
    private static func navigation(in controller: UIViewController) -> UINavigationController? {
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { return navigation(in: selected) }
        if let nav = controller as? UINavigationController, nav.viewIfLoaded?.window != nil {
            if let inner = nav.topViewController.flatMap({ navigation(in: $0) }), inner.viewControllers.count > 1 { return inner }
            return nav
        }
        for child in controller.children where child.viewIfLoaded?.window != nil { if let found = navigation(in: child) { return found } }
        return nil
    }

    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var found: String?
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = item.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { found = String(cString: host) }
        }
        return found
    }
}

extension UIResponder {
    private static weak var found: UIResponder?
    /// The view that currently has the keyboard focus.
    static var currentFirst: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.captureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    @objc private func captureFirstResponder() { UIResponder.found = self }
}

/// Settings section of the special build: start/stop and the address and token for the computer.
struct DevRemoteSection: View {
    @ObservedObject private var remote = DevRemote.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Section {
            Toggle("Управление с компьютера", isOn: Binding(get: { remote.running }, set: { $0 ? remote.start() : remote.stop() }))
                .accessibilityIdentifier("dev-remote")
            if !remote.address.isEmpty { LabeledContent("Адрес", value: remote.address).textSelection(.enabled) }
            LabeledContent("Токен", value: remote.token).textSelection(.enabled)
            if !remote.lastCommand.isEmpty { LabeledContent("Последняя команда", value: remote.lastCommand) }
        } header: { Text("Специальная сборка") } footer: {
            Text("Только для проверки: компьютер в той же сети Wi-Fi читает экран и нажимает кнопки по подписям. Работает, пока АниПолка открыта; при уходе с экрана выключается. iOS может спросить разрешение на доступ к локальной сети.")
        }
        .onChange(of: phase) { _, value in if value == .background { remote.stop() } }
    }
}
#endif
