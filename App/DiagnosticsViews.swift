import SwiftUI
import UserNotifications

/// Health of every outside source: last success, last failure with its text, request count. Kept on this iPhone.
@MainActor final class SourceHealth: ObservableObject {
    static let shared = SourceHealth()
    struct Record: Codable, Equatable {
        var lastOK: Date?
        var lastFailure: Date?
        var error: String?
        var requests = 0
        var failures = 0
    }
    /// Known hosts with their names, in the order shown.
    static let sources: [(host: String, name: String, role: String)] = [
        ("anivibe.pro", "AniVibe", "Новые серии в русской озвучке, страницы просмотра"),
        ("shikimori.io", "Shikimori", "Каталог, обложки, даты выхода, франшизы, описание"),
        ("graphql.anilist.co", "AniList", "Точное время и номер следующей серии"),
        ("anilibria.top", "AniLibria", "Расписание озвучки AniLibria"),
        ("kitsu.io", "Kitsu", "Запасной поиск и обложки"),
        ("myanimelist.net", "MyAnimeList", "Импорт списка по нику"),
        ("api.bgm.tv", "Bangumi", "Даты серий китайских и японских тайтлов"),
        ("t.me", "Telegram", "Каналы студий озвучки (часто только через VPN)"),
    ]
    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var log: [String] = []
    private let key = "sourceHealth"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([String: Record].self, from: data) { records = saved }
        log = UserDefaults.standard.stringArray(forKey: key + ".log") ?? []
    }
    func record(host: String, error: Error?) {
        var r = records[host] ?? Record()
        r.requests += 1
        if let error {
            r.failures += 1; r.lastFailure = Date(); r.error = error.localizedDescription
            let name = Self.sources.first { $0.host == host }?.name ?? host
            log.insert("\(Date().formatted(date: .numeric, time: .shortened)) · \(name): \(error.localizedDescription)", at: 0)
            if log.count > 50 { log.removeLast(log.count - 50) }
            UserDefaults.standard.set(log, forKey: key + ".log")
        } else { r.lastOK = Date() }
        records[host] = r
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }
    /// Green when the last request succeeded, red when it failed, grey when never used.
    func state(_ host: String) -> (Color, String) {
        guard let r = records[host] else { return (.gray, "ещё не было запросов") }
        if let ok = r.lastOK, r.lastFailure == nil || ok > r.lastFailure! { return (.green, "работает · " + agoText(ok)) }
        return (.red, "ошибка · " + (r.lastFailure.map { agoText($0) } ?? ""))
    }
    func clear() { records = [:]; log = []; UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: key + ".log") }
}

/// «Диагностика»: sources, collection, notifications and backups at a glance, with a report to copy.
struct DiagnosticsView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @ObservedObject private var health = SourceHealth.shared
    @State private var notifications = "…"
    @State private var copied = false
    var body: some View {
        List {
            Section {
                ForEach(SourceHealth.sources, id: \.host) { source in
                    let state = health.state(source.host)
                    let color = state.0, text = state.1
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Circle().fill(color).frame(width: 10, height: 10); Text(source.name).font(.headline); Spacer(); Text(text).font(.caption).foregroundStyle(.secondary) }
                        Text(source.role).font(.caption).foregroundStyle(.secondary)
                        if let r = health.records[source.host], let error = r.error, color == .red { Text(error).font(.caption).foregroundStyle(.red) }
                        if let r = health.records[source.host] { Text("Запросов: \(r.requests), ошибок: \(r.failures)").font(.caption2).foregroundStyle(.tertiary) }
                    }.padding(.vertical, 2)
                }
                Button { Task { await assistant.checkReleases(); await assistant.refreshAiring(force: true) } } label: {
                    HStack { Label("Проверить все источники", systemImage: "arrow.clockwise"); if assistant.checking || assistant.refreshingAiring { Spacer(); ProgressView() } }
                }.disabled(assistant.checking || assistant.refreshingAiring)
                if !assistant.sourcesReport.isEmpty { Text(assistant.sourcesReport).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Источники") } footer: { Text("Зелёный — последний запрос прошёл, красный — последний запрос с ошибкой (её текст ниже), серый — источник ещё не использовался.") }

            Section("Коллекция") {
                LabeledContent("Тайтлов", value: "\(store.snapshot.entries.count)")
                LabeledContent("С привязкой к Shikimori", value: "\(store.snapshot.entries.filter { $0.sourceID != nil }.count)")
                LabeledContent("Подключено источников AniVibe", value: "\(store.snapshot.entries.reduce(0) { $0 + ($1.subscriptions ?? []).count })")
                LabeledContent("Источников с ошибкой", value: "\(store.snapshot.entries.reduce(0) { $0 + ($1.subscriptions ?? []).filter { $0.error != nil }.count })")
                LabeledContent("Франшиз", value: "\(store.snapshot.franchises?.count ?? 0)")
                LabeledContent("Непрочитанных выпусков", value: "\(NoticeInbox.unread(store.snapshot))")
                if let error = store.loadFailure { Text(error).font(.caption).foregroundStyle(.red) }
                let connected = store.snapshot.entries.filter { !($0.subscriptions ?? []).isEmpty }
                if !connected.isEmpty {
                    NavigationLink {
                        List(connected) { entry in
                            NavigationLink { EntryDetail(id: entry.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title)
                                    Text("Источников: \((entry.subscriptions ?? []).count)").font(.caption).foregroundStyle(.secondary)
                                    ForEach((entry.subscriptions ?? []).compactMap(\.error), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                        }.navigationTitle("Подключённые истории")
                    } label: { LabeledContent("Подключённые истории", value: "\(connected.count)") }
                }
            }
            Section("Уведомления и копии") {
                LabeledContent("Разрешение на уведомления", value: notifications)
                LabeledContent("Уведомления о новых сериях", value: store.snapshot.preferences.releaseNotifications ? "вкл." : "выкл.")
                LabeledContent("Фоновые проверки", value: store.snapshot.preferences.backgroundChecks ? "вкл." : "выкл.")
                LabeledContent("Автокопия", value: AutoBackup.enabled ? (AutoBackup.last.map { agoText($0) } ?? "включена") : "выкл.")
                if AutoBackup.enabled, !AutoBackup.inICloud { Text("Папка автокопий не в iCloud Drive: при удалении приложения или слёте подписи копии в ней могут пропасть. Выберите папку в iCloud Drive.").font(.caption).foregroundStyle(.orange) }
            }
            if !health.log.isEmpty {
                Section("Журнал ошибок") { ForEach(Array(health.log.prefix(20).enumerated()), id: \.offset) { Text($0.element).font(.caption) } }
            }
            Section {
                Button { UIPasteboard.general.string = report(); copied = true } label: { Label(copied ? "Отчёт скопирован" : "Скопировать отчёт", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: report()) { Label("Поделиться отчётом", systemImage: "square.and.arrow.up") }
                Button("Очистить журнал", role: .destructive) { health.clear() }
            } footer: { Text("Отчёт — обычный текст без названий тайтлов: версии, состояние источников и последние ошибки.") }
        }
        .navigationTitle("Диагностика").feedbackScreen("Диагностика")
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: notifications = "есть"
            case .denied: notifications = "запрещено"
            default: notifications = "не спрашивали"
            }
        }
    }
    private func report() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")"
        var lines = ["АниПолка \(version) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", "Тайтлов: \(store.snapshot.entries.count), франшиз: \(store.snapshot.franchises?.count ?? 0), непрочитанных: \(NoticeInbox.unread(store.snapshot))"]
        for source in SourceHealth.sources {
            let (_, text) = health.state(source.host)
            var line = "\(source.name): \(text)"
            if let r = health.records[source.host] { line += " · запросов \(r.requests), ошибок \(r.failures)"; if let e = r.error { line += " · последняя ошибка: \(e)" } }
            lines.append(line)
        }
        if !assistant.sourcesReport.isEmpty { lines.append(assistant.sourcesReport) }
        lines.append(contentsOf: health.log.prefix(10))
        return lines.joined(separator: "\n")
    }
}
