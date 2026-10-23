import SwiftUI
import UIKit

@MainActor final class ShelfStore: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var error: String?
    @Published private(set) var loadFailure: String?
    @Published private(set) var undoToken: EpisodeUndo?
    private var repository: ShelfRepository?
    private let fileURL: URL
    private var undoTask: Task<Void, Never>?
    let demo: Bool
    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--demo")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = base.appendingPathComponent(demo ? "AniPolka-preview/shelf.json" : "AniPolka/shelf.json")
        do { repository = try ShelfRepository(url: fileURL); snapshot = repository!.snapshot }
        catch { loadFailure = "Локальный файл не удалось прочитать. Он сохранён без изменений. Восстановите резервную копию в настройках.\n\(error.localizedDescription)" }
        if demo && ProcessInfo.processInfo.arguments.contains("--reset") {
            var preview = Snapshot()
            let titles = ["Хроники далёких созвездий", "Путь за облаками", "Легенда о красном драконе", "Странник между мирами", "Очень длинное название истории о путешествии к краю бесконечной вселенной", "Последний хранитель"]
            for (i, title) in titles.enumerated() {
                var e = Entry(title: title, episode: [24,26,20,11,150,48][i]); e.favorite = i == 0
                e.coverData = DemoArt.cover(index: i); e.watchedAt = Date().addingTimeInterval(Double(-i * 3600)); preview.entries.append(e)
            }
            let source = ReleaseSubscription(pageURL:"https://anivibe.pro/anime/44218",optionID:"kodik-910-1",label:"Тестовая озвучка · сезон 1 · Kodik",episode:26)
            preview.entries[0].subscriptions = [source]; preview.entries[0].watchURL = source.pageURL
            preview.entries[0].releaseNotices = [ReleaseNotice(subscription:source,entryTitle:preview.entries[0].title,episode:27,url:source.pageURL + "?episode=27&translation=910")]
            if ProcessInfo.processInfo.arguments.contains("--live-covers") {
                var probe = Entry(title:"Tunshi Xingkong",episode:24); probe.watchedAt = Date(); preview.entries.insert(probe,at:0)
            }
            try? repository?.commit(preview); snapshot = preview
        }
    }
    @discardableResult func change(_ block: (inout Snapshot) -> Void) -> Bool {
        guard let repository else { error = loadFailure; return false }
        var next = snapshot; block(&next)
        do { try repository.commit(next); snapshot = repository.snapshot; return true }
        catch { self.error = "Не удалось сохранить: \(error.localizedDescription)"; return false }
    }
    @discardableResult func save(_ entry: Entry) -> Bool {
        change { state in
            if let i = state.entries.firstIndex(where: { $0.id == entry.id }) { state.entries[i] = entry }
            else { state.entries.append(entry) }
        }
    }
    func increment(_ entry: Entry) {
        do {
            guard let repository, let token = try repository.increment(entry.id) else { return }
            snapshot = repository.snapshot; undoToken = token
            if snapshot.preferences.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            undoTask?.cancel(); undoTask = Task { try? await Task.sleep(for: .seconds(6)); if !Task.isCancelled { undoToken = nil } }
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        guard let token = undoToken, let repository else { return }
        do { try repository.undo(token); snapshot = repository.snapshot; undoToken = nil; undoTask?.cancel() }
        catch { self.error = error.localizedDescription }
    }
    func cacheCover(id: UUID, url: String, data: Data) {
        guard let i = snapshot.entries.firstIndex(where: { $0.id == id }), snapshot.entries[i].coverURL == url, snapshot.entries[i].coverData == nil else { return }
        _ = change { $0.entries[i].coverData = data }
    }
    func restore(_ backup: Snapshot, replacing: Bool) -> Bool {
        do {
            let validated = try backup.validated()
            if repository == nil {
                guard replacing else { error = "Для повреждённой коллекции выберите восстановление с заменой."; return false }
                // Keep the unreadable file for recovery before restoring a known-valid copy.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let preserved = fileURL.deletingLastPathComponent().appendingPathComponent("unreadable-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: fileURL, to: preserved)
                    try validated.encoded().write(to: fileURL, options: .atomic)
                }
                repository = try ShelfRepository(url: fileURL)
            }
            let success = change { if replacing { $0 = validated } else { $0.merge(validated) } }
            if success { loadFailure = nil; undoToken = nil }; return success
        } catch { self.error = error.localizedDescription; return false }
    }
    func preference<T>(_ path: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { self.snapshot.preferences[keyPath: path] }, set: { value in _ = self.change { $0.preferences[keyPath: path] = value } })
    }
}

enum DemoArt {
    static func cover(index: Int) -> Data? {
        let colors: [[UIColor]] = [[.init(red:0.03,green:0.13,blue:0.32,alpha:1), .systemBlue], [.init(red:0.2,green:0.14,blue:0.3,alpha:1), .systemOrange], [.init(red:0.26,green:0.03,blue:0.1,alpha:1), .systemRed], [.init(red:0.03,green:0.21,blue:0.24,alpha:1), .systemTeal]]
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 840)).image { ctx in
            let c = ctx.cgContext, palette = colors[index % colors.count]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: palette.map(\.cgColor) as CFArray, locations: [0,1])!
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x:640,y:840), options: [])
            c.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
            for i in 0..<110 { let x = (i * 97 + index * 13) % 640, y = (i * 53) % 520; c.fillEllipse(in: CGRect(x:x,y:y,width:i % 3 + 1,height:i % 3 + 1)) }
            c.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor); c.fillEllipse(in: CGRect(x:330,y:100,width:230,height:230))
            for layer in 0..<4 {
                c.setFillColor(UIColor.black.withAlphaComponent(0.18 + Double(layer) * 0.12).cgColor)
                let p = CGMutablePath(); p.move(to: CGPoint(x:0,y:840)); p.addLine(to: CGPoint(x:0,y:520 + layer * 40))
                for i in 0...8 { p.addLine(to: CGPoint(x:i * 90,y:380 + layer * 90 + (i % 2) * 130)) }; p.addLine(to: CGPoint(x:640,y:840)); p.closeSubpath(); c.addPath(p); c.fillPath()
            }
        }.jpegData(compressionQuality: 0.9)
    }
}
