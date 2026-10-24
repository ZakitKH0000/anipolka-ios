import AppIntents

/// «+1» from Control Center. Compiled into the app and the widget extension; because it opens
/// the app, iOS performs it in the app process, which owns the collection. This works even
/// when the signing tool removed the shared App Group.
struct MarkLatestEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "+1 серия в последней истории"
    static var description = IntentDescription("Отмечает следующую серию в истории со статусом «Смотрю», которую вы смотрели последней, и открывает АниПолку с кнопкой отмены.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let store = ShelfStore.shared
        guard let entry = ReleasePlanner.continuing(store.snapshot.entries,limit:1).first else {
            throw ShelfError.invalid("Нет историй со статусом «Смотрю».")
        }
        store.increment(id:entry.id)
        #endif
        return .result()
    }
}
