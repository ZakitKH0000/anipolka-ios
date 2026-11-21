import SwiftUI
import UIKit

// MARK: «Предложить / Ошибка»

/// An idea or a problem the owner reports from the app: text, a screenshot of the screen and where it was taken.
struct FeedbackItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var text: String
    var screen: String
    var createdAt = Date()
    var version: String
    var done = false
}

/// Kept in the app's own folder, not in the collection or backups. The special build hands them to the computer.
@MainActor final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()
    @Published private(set) var items: [FeedbackItem] = []
    /// The screen at the moment of the shake or tap, taken before the form covers it.
    @Published var pendingShot: Data?
    @Published var composing = false
    var lastScreen = ""
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AniPolka/feedback", isDirectory: true)
    private var index: URL { folder.appendingPathComponent("feedback.json") }
    private init() {
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([FeedbackItem].self, from: data) { items = saved }
    }
    func imageURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).jpg") }
    func image(_ id: UUID) -> Data? { try? Data(contentsOf: imageURL(id)) }
    /// Takes the screenshot first, then opens the form.
    func begin() {
        pendingShot = Self.snapshot()
        composing = true
    }
    func add(kind: String, text: String, shot: Data?) {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")"
        let item = FeedbackItem(kind: kind, text: String(text.prefix(4000)), screen: lastScreen, version: version)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let shot { try? shot.write(to: imageURL(item.id), options: .atomic) }
        items.insert(item, at: 0)
        if items.count > 200 { for old in items.suffix(from: 200) { try? FileManager.default.removeItem(at: imageURL(old.id)) }; items = Array(items.prefix(200)) }
        save()
    }
    func setDone(_ id: UUID, _ done: Bool = true) { if let i = items.firstIndex(where: { $0.id == id }) { items[i].done = done; save() } }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; try? FileManager.default.removeItem(at: imageURL(id)); save() }
    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: index, options: .atomic) }
    }
    static func snapshot() -> Data? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = min(2, window.traitCollection.displayScale)
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return image.jpegData(compressionQuality: 0.7)
    }
}

extension Notification.Name { static let deviceDidShake = Notification.Name("AniPolkaDeviceDidShake") }
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
    }
}

/// Remembers which screen the owner is on, so a report says where the problem is.
extension View {
    func feedbackScreen(_ name: String) -> some View { onAppear { FeedbackStore.shared.lastScreen = name } }
}

struct FeedbackSheet: View {
    @ObservedObject private var feedback = FeedbackStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "Идея"
    @State private var text = ""
    @State private var attach = true
    @State private var sent = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Что это", selection: $kind) { Text("Идея").tag("Идея"); Text("Ошибка").tag("Ошибка"); Text("Дизайн").tag("Дизайн") }.pickerStyle(.segmented)
                    TextField(kind == "Ошибка" ? "Что пошло не так? Например: «на карточке белая полоса»" : "Что хочется добавить или поменять?", text: $text, axis: .vertical)
                        .lineLimit(4...12).accessibilityIdentifier("feedback-text")
                }
                if let shot = feedback.pendingShot, let image = UIImage(data: shot) {
                    Section {
                        Toggle("Приложить снимок экрана", isOn: $attach)
                        if attach { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity) }
                    } footer: { Text("Экран: \(feedback.lastScreen.isEmpty ? "—" : feedback.lastScreen)") }
                }
                Section {
                    Text("Сообщение остаётся на iPhone. В специальной сборке его забирает компьютер по Wi-Fi; в обычной — отправьте через «Студию» → «Мои сообщения» → «Поделиться».").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(kind == "Ошибка" ? "Сообщить об ошибке" : "Предложить").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { feedback.add(kind: kind, text: text, shot: attach ? feedback.pendingShot : nil); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("feedback-save")
                }
            }
        }
    }
}

struct FeedbackListView: View {
    @ObservedObject private var feedback = FeedbackStore.shared
    var body: some View {
        List {
            if feedback.items.isEmpty { ContentUnavailableView("Сообщений пока нет", systemImage: "bubble.left.and.text.bubble.right", description: Text("Встряхните iPhone на любом экране или нажмите «Предложить / Ошибка».")) }
            ForEach(feedback.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    if let data = feedback.image(item.id), let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 90).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(item.kind).font(.caption.bold()).foregroundStyle(item.kind == "Ошибка" ? Color.red : Color.blue); if item.done { Label("сделано", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) } }
                        Text(item.text).font(.subheadline)
                        Text("\(item.screen.isEmpty ? "" : item.screen + " · ")\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(item.version)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button("Удалить", systemImage: "trash", role: .destructive) { feedback.remove(item.id) } }
                .swipeActions(edge: .leading) { Button(item.done ? "Не сделано" : "Сделано", systemImage: "checkmark") { feedback.setDone(item.id, !item.done) }.tint(.green) }
                .contextMenu {
                    ShareLink(item: shareText(item)) { Label("Поделиться текстом", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle("Мои сообщения")
        .toolbar { if !feedback.items.isEmpty { ShareLink(item: feedback.items.map(shareText).joined(separator: "\n\n")) { Image(systemName: "square.and.arrow.up") } } }
    }
    private func shareText(_ item: FeedbackItem) -> String { "АниПолка \(item.version) · \(item.kind) · \(item.screen)\n\(item.text)" }
}

// MARK: «Что нового»

enum WhatsNew {
    static let version = "1.4"
    static let items: [(String, String, String)] = [
        ("square.stack.3d.up.fill", "Одна карточка на франшизу", "Сезоны, фильмы и спецвыпуски одной истории в одной карточке со вкладками. Недостающие части добавляются одним нажатием."),
        ("number", "Нумерация на выбор", "Для каждой франшизы: по сезонам, как на сайтах, или сквозная, как привыкли вы."),
        ("play.rectangle.fill", "Просмотр внутри АниПолки", "Нужная серия и озвучка. Досмотрели — «+1» сам, закрыли на середине — минута сохранится в «Где остановился»."),
        ("party.popper.fill", "Следующий сезон и «Догнать к выходу»", "Подсказка, когда сезон досмотрен, и сколько серий в день смотреть до выхода новой части."),
        ("bell.badge.fill", "Уведомления в порядке", "Серии, отмеченные «+1», читаются сами. «Прочитать все», удаление и автоочистка через 30 дней."),
        ("calendar", "Календарь и отсчёт", "Даты выхода из Shikimori, календарь на неделю, обратный отсчёт на обложках."),
        ("sun.max.fill", "Вкладка «Сегодня»", "Что вышло, что продолжить, что выходит сегодня и что догнать — на одном экране."),
        ("safari.fill", "Вкладка «Обзор»", "Дунхуа и онгоинги, анонсы, лучшие тайтлы и поиск — добавление в одно нажатие."),
        ("text.book.closed.fill", "О тайтле", "Сюжет, жанры, студия, оценка, кадры, трейлеры и похожие тайтлы прямо в карточке."),
        ("hand.wave.fill", "Студия", "Встряхните iPhone — и предложите идею или сообщите об ошибке со снимком экрана."),
    ]
    static func shouldShow() -> Bool { UserDefaults.standard.string(forKey: "whatsNewSeen") != version }
    static func markSeen() { UserDefaults.standard.set(version, forKey: "whatsNewSeen") }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Что нового в АниПолке \(WhatsNew.version)").font(.largeTitle.bold()).padding(.top, 8)
                    ForEach(WhatsNew.items, id: \.1) { icon, title, text in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 36)
                            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button { WhatsNew.markSeen(); dismiss() } label: { Text("Отлично").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }
                    .buttonStyle(.borderedProminent).padding(.horizontal, 24).padding(.bottom, 8).accessibilityIdentifier("whats-new-done")
            }
        }
        .onDisappear { WhatsNew.markSeen() }
    }
}

// MARK: «Лаборатория»

/// Experimental features the owner can switch on and off; stored on this iPhone only.
enum Lab {
    static let inAppPlayer = "lab.inAppPlayer"
    static let shakeFeedback = "lab.shakeFeedback"
    static let celebrate = "lab.celebrate"
}

struct LabView: View {
    @EnvironmentObject var store: ShelfStore
    @AppStorage(Lab.inAppPlayer) private var inAppPlayer = true
    @AppStorage(Lab.shakeFeedback) private var shakeFeedback = true
    var body: some View {
        Form {
            Section {
                Toggle("Просмотр внутри АниПолки", isOn: $inAppPlayer)
                Toggle("Одна карточка на франшизу", isOn: store.preference(\.groupFranchises))
                Toggle("Встряхнуть — сообщить об ошибке", isOn: $shakeFeedback)
            } footer: { Text("Экспериментальные функции: если что-то мешает, просто выключите. Данные коллекции не меняются.") }
        }
        .navigationTitle("Лаборатория")
    }
}

/// Settings section of the studio: report, messages, what's new and the lab.
struct StudioSection: View {
    @ObservedObject private var feedback = FeedbackStore.shared
    @State private var showWhatsNew = false
    var body: some View {
        Section {
            Button { feedback.begin() } label: { Label("Предложить / Ошибка", systemImage: "bubble.left.and.exclamationmark.bubble.right") }.accessibilityIdentifier("open-feedback")
            NavigationLink { FeedbackListView() } label: { LabeledContent { Text("\(feedback.items.filter { !$0.done }.count)") } label: { Label("Мои сообщения", systemImage: "tray.full") } }
            Button { showWhatsNew = true } label: { Label("Что нового", systemImage: "sparkles") }
            NavigationLink { LabView() } label: { Label("Лаборатория", systemImage: "flask") }
        } header: { Text("Студия") } footer: { Text("Встряхните iPhone на любом экране, чтобы быстро предложить идею или сообщить об ошибке со снимком экрана.") }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
    }
}
