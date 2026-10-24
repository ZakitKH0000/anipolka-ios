import AppIntents

struct ShelfEntryEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "История"
    static var defaultQuery = ShelfEntryQuery()
    var id: UUID
    var title: String
    var episode: Int
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title:"\(title)",subtitle:"Серия \(episode)") }
    init(_ entry: Entry) { id = entry.id; title = entry.title; episode = entry.episode }
}

struct ShelfEntryQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ShelfEntryEntity] {
        ShelfStore.shared.snapshot.entries.filter { identifiers.contains($0.id) }.map(ShelfEntryEntity.init)
    }
    @MainActor func entities(matching string: String) async throws -> [ShelfEntryEntity] {
        ShelfStore.shared.snapshot.visible(query:string).map(ShelfEntryEntity.init)
    }
    /// Titles in progress first, so Siri and Shortcuts offer what is actually being watched.
    @MainActor func suggestedEntities() async throws -> [ShelfEntryEntity] {
        let entries = ShelfStore.shared.snapshot.entries
        let watching = ReleasePlanner.continuing(entries,limit:entries.count)
        return (watching + entries.filter { $0.status != .watching }).map(ShelfEntryEntity.init)
    }
}

struct MarkEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Отметить серию"
    static var description = IntentDescription("Увеличивает номер последней просмотренной серии на 1, как кнопка «+1».")
    @Parameter(title:"История") var entry: ShelfEntryEntity
    static var parameterSummary: some ParameterSummary { Summary("Отметить серию: \(\.$entry)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let updated = ShelfStore.shared.increment(id:entry.id) else {
            throw ShelfError.invalid("Не удалось отметить серию. Откройте АниПолку и проверьте запись.")
        }
        return .result(dialog:"«\(updated.title)»: отмечена серия \(updated.episode).")
    }
}

/// In Shortcuts this action can receive links from the share sheet («Показывать в меню
/// „Поделиться“»), so a page from Safari or AniVibe goes straight to a chosen title.
struct AddLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Добавить ссылку в АниПолку"
    static var description = IntentDescription("Открывает АниПолку, чтобы привязать ссылку к истории: как страницу просмотра или как источник AniVibe.")
    static var openAppWhenRun = true
    @Parameter(title:"Ссылка") var url: URL
    @MainActor func perform() async throws -> some IntentResult {
        guard validWebURL(url.absoluteString) != nil else { throw ShelfError.invalid("Нужна ссылка, начинающаяся с http:// или https://.") }
        ShelfStore.shared.pendingLink = url
        return .result()
    }
}

struct AniPolkaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent:MarkEpisodeIntent(),phrases:[
            "Отметить серию в \(.applicationName)",
            "Плюс одна серия в \(.applicationName)",
            "Mark episode in \(.applicationName)"
        ],shortTitle:"Отметить серию",systemImageName:"plus.circle")
        AppShortcut(intent:AddLinkIntent(),phrases:["Добавить ссылку в \(.applicationName)"],shortTitle:"Добавить ссылку",systemImageName:"link.badge.plus")
    }
}
