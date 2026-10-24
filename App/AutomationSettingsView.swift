import SwiftUI

struct AutomationSettingsView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @State private var askingPermission = false
    @State private var permissionMessage: String?
    var body: some View {
        Group {
            DigestSettingsSection()
            Section {
                Text(WidgetBridge.shared.available ? "Виджеты получают данные коллекции: «Продолжить просмотр» на экране «Домой» и строка на экране блокировки." : "Общая папка для виджетов недоступна: способ подписи не сохранил App Group. Приложение работает полностью, а виджет покажет подсказку вместо списка.").font(.footnote).foregroundStyle(.secondary)
                Text("Ссылки из меню «Поделиться»: в приложении «Команды» создайте команду с действием «Добавить ссылку в АниПолку» и включите «Показывать в меню „Поделиться“» для ссылок.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Виджеты и «Команды»") }
            Section {
                Toggle("Автоматически искать обложки",isOn:store.preference(\.automaticCovers)).accessibilityIdentifier("automatic-covers")
                Button { assistant.queueCovers(force:true) } label: { HStack { Text("Найти недостающие обложки"); if assistant.findingCovers { Spacer(); ProgressView() } } }.disabled(assistant.findingCovers)
            } header: { Text("Автообложки") } footer: { Text("Обложка сохраняется при единственном точном совпадении названия. Ваше название и прогресс не меняются. Если вариантов несколько, их можно выбрать в карточке. Свои обложки и явно убранные изображения не заменяются.") }
            Section {
                Toggle("Фоновые проверки серий",isOn:store.preference(\.backgroundChecks)).onChange(of:store.snapshot.preferences.backgroundChecks) { _, _ in assistant.scheduleBackground() }
                Toggle("Уведомлять о новых сериях",isOn:Binding(get:{store.snapshot.preferences.releaseNotifications},set:{ value in
                    if !value { _ = store.change { $0.preferences.releaseNotifications = false }; return }
                    askingPermission = true
                    Task {
                        let allowed = await NotificationBridge.shared.enable()
                        _ = store.change { $0.preferences.releaseNotifications = allowed }
                        permissionMessage = allowed ? "Уведомления включены для новых серий выбранных источников." : "Уведомления не разрешены. Их можно включить в Настройках iPhone → АниПолка → Уведомления. Найденные серии всё равно появятся во вкладке «Серии»."
                        askingPermission = false
                    }
                })).disabled(askingPermission).accessibilityIdentifier("release-notifications")
                if askingPermission { ProgressView() }
                if let permissionMessage { Text(permissionMessage).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Новые серии") } footer: { Text("В карточке истории выберите страницу AniVibe, сезон и озвучку. iOS сама назначает время фоновой проверки: мгновенные уведомления без сервера не гарантируются. При принудительном закрытии приложения проверки могут не выполняться до следующего открытия. Кнопка «Проверить сейчас» — во вкладке «Серии».") }
        }
    }
}
