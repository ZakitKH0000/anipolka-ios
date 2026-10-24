import SwiftUI
import Charts
import LocalAuthentication

struct TitleHistoryView: View {
    let id: UUID
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let marks = WatchHistory.marks(for:id,in:store.snapshot)
        let weeks = WatchHistory.weekly(marks,weeks:12)
        List {
            Section {
                Chart(weeks,id:\.start) { week in
                    BarMark(x:.value("Неделя",week.start,unit:.weekOfYear),y:.value("Серии",week.episodes)).foregroundStyle(.blue)
                }.frame(height:160)
                    .accessibilityLabel("Серии по неделям за 12 недель: всего \(weeks.reduce(0) { $0 + $1.episodes })")
            } header: { Text("Последние 12 недель") }
            Section("Отметки") {
                if marks.isEmpty { Text("Отметок пока нет. Они появляются после «+1» или изменения номера серии начиная с версии 1.2.").foregroundStyle(.secondary) }
                ForEach(Array(marks.prefix(300).enumerated()),id:\.offset) { _, mark in
                    HStack {
                        Text("+\(mark.episodes) \(episodesWord(mark.episodes))")
                        Spacer()
                        Text(mark.at.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("История просмотра").navigationBarTitleDisplayMode(.inline)
    }
}

/// «Что посмотреть?»: a random title with new episodes or from «На потом».
struct SuggestionView: View {
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var current: UUID?
    var body: some View {
        NavigationStack {
            Group {
                if let id = current, store.snapshot.entries.contains(where:{$0.id == id}) { EntryDetail(id:id) }
                else { ContentUnavailableView("Нечего предложить",systemImage:"dice",description:Text("Здесь появятся истории «На потом» и те, у которых в источнике есть новые серии.")) }
            }
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement:.primaryAction) { Button("Другое",systemImage:"dice") { pick() }.disabled(WatchSuggestion.pool(store.snapshot.entries).count < 2) }
            }
        }.onAppear { if current == nil { pick() } }
    }
    private func pick() {
        var generator = SystemRandomNumberGenerator()
        current = WatchSuggestion.pick(store.snapshot.entries,excluding:current,using:&generator)?.id
    }
}

/// A link received from Shortcuts (for example from the share sheet), attached by the user to a title.
struct LinkInboxView: View {
    let url: URL
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var connecting: OpenedEntry?
    @State private var saved: String?
    private var anivibe: AnivibeCatalog.Page? { AnivibeCatalog.pages(in:[url.absoluteString]).first }
    private var entries: [Entry] {
        let all = store.snapshot.visible(query:query)
        guard let page = anivibe else { return all }
        // Titles whose names match the page address come first.
        let likely = all.filter { TitleMatcher.matches([page.slugName],$0) }
        return likely + all.filter { e in !likely.contains { $0.id == e.id } }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(url.absoluteString).font(.footnote).textSelection(.enabled)
                    if let saved { Label(saved,systemImage:"checkmark.circle").font(.footnote).foregroundStyle(.green) }
                } footer: { Text("Выберите историю. Ссылку можно сохранить как страницу просмотра, а страницу AniVibe — подключить как источник новых серий.") }
                ForEach(entries) { entry in
                    Menu {
                        Button("Сделать ссылкой просмотра",systemImage:"play.rectangle") {
                            if store.change({ state in if let i = state.entries.firstIndex(where:{$0.id == entry.id}) { state.entries[i].watchURL = url.absoluteString } }) { saved = "Ссылка сохранена в «\(entry.title)»." }
                        }
                        if AnivibePageParser.canonicalURL(url.absoluteString) != nil {
                            Button("Подключить как источник AniVibe",systemImage:"bell.badge") { connecting = OpenedEntry(id:entry.id) }
                        }
                    } label: {
                        VStack(alignment:.leading,spacing:3) { Text(entry.title).foregroundStyle(.primary); Text(entry.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .searchable(text:$query,prompt:"Найти историю")
            .navigationTitle("Добавить ссылку").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Готово") { dismiss() } } }
            .sheet(item:$connecting) { item in EntrySourcesView(entryID:item.id,initialAddress:url.absoluteString) }
        }
    }
}

struct OpenedLink: Identifiable { let url: URL; var id: String { url.absoluteString } }

@MainActor final class AppLock: ObservableObject {
    @Published private(set) var locked: Bool
    @Published private(set) var failure: String?
    private var unlocking = false
    init(enabled: Bool) { locked = enabled }
    static var available: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication,error:nil) }
    func lock() { locked = true }
    /// Face ID with the iPhone passcode as fallback.
    @discardableResult func authenticate(reason: String = "Открыть коллекцию АниПолки") async -> Bool {
        guard !unlocking else { return false }
        unlocking = true; defer { unlocking = false }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication,error:nil) else {
            // Without a passcode iOS cannot protect anything; do not lock the user out.
            locked = false; failure = nil; return true
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:reason)
            if ok { locked = false; failure = nil }
            return ok
        } catch { failure = "Не удалось подтвердить. Попробуйте ещё раз."; return false }
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        VStack(spacing:18) {
            Image(systemName:"lock.fill").font(.system(size:44,weight:.light)).foregroundStyle(.blue)
            Text("АниПолка заблокирована").font(.title3.bold())
            if lock.locked {
                Button("Разблокировать",systemImage:"faceid") { Task { await lock.authenticate() } }.buttonStyle(.borderedProminent).controlSize(.large)
                if let failure = lock.failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(ShelfDesign.background.ignoresSafeArea())
    }
}

struct PrivacySettingsSection: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var lock: AppLock
    @State private var message: String?
    var body: some View {
        Section {
            Toggle("Замок Face ID",isOn:Binding(get:{store.snapshot.preferences.appLock},set:{ value in
                Task {
                    guard !value || AppLock.available else { message = "На iPhone не настроен код-пароль, поэтому замок недоступен."; return }
                    // Confirm with Face ID before changing protection in either direction.
                    if await lock.authenticate(reason:value ? "Включить замок АниПолки" : "Выключить замок АниПолки") {
                        _ = store.change { $0.preferences.appLock = value }; message = nil
                    }
                }
            })).accessibilityIdentifier("app-lock")
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: { Text("Конфиденциальность") } footer: { Text("Коллекция закрывается при уходе из приложения и открывается по Face ID или код-паролю iPhone. Виджеты и уведомления показывают названия и без разблокировки — их можно убрать в настройках iPhone.") }
    }
}
