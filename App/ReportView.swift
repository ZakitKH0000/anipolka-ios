import SwiftUI
import UIKit

/// Settings → «Текст для копирования»: the whole collection as plain text for notes,
/// a chat with a friend or an AI assistant. Built on the phone; nothing is sent anywhere.
struct ReportView: View {
    @EnvironmentObject var store: ShelfStore
    @State private var options = ReportOptions()
    @State private var copied = false
    private let previewLimit = 6000

    private var hint: String {
        switch options.style {
        case .brief: return "Одна строка на историю: название и серия, на которой вы остановились."
        case .detailed: return "Статус, серия, источники и «+N», оценка, метки, дни выхода, где остановились, последний просмотр."
        case .forAI: return "То же, что «Подробно», плюс короткое пояснение для ИИ в начале и строка «Мой вопрос:» в конце."
        }
    }

    var body: some View {
        let text = ShelfReport.text(store.snapshot,options:options)
        List {
            Section {
                Picker("Формат",selection:$options.style) { ForEach(ReportOptions.Style.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("report-style")
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Формат") }
            Section {
                ForEach(WatchStatus.allCases) { status in
                    Toggle("\(status.rawValue) · \(count(status))",isOn:binding(status))
                }
                Toggle("Итоги и статистика",isOn:$options.statistics)
                Toggle("Заметки и «где остановился»",isOn:$options.notes).disabled(options.style == .brief)
                Toggle("Ссылки",isOn:$options.links).disabled(options.style == .brief)
            } header: { Text("Что включить") } footer: { Text("Итоги считаются по всей коллекции. Ссылки по умолчанию выключены: в них могут быть личные плейлисты.") }
            Section {
                Text(String(text.prefix(previewLimit)) + (text.count > previewLimit ? "\n…" : ""))
                    .font(.system(.footnote,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    .accessibilityIdentifier("report-preview")
            } header: { Text("Предпросмотр") } footer: { Text(text.count > previewLimit ? "Предпросмотр сокращён, копируется весь текст (\(text.count) символов)." : "\(text.count) символов.") }
            Section {
                Button { copy(text) } label: { Label(copied ? "Скопировано" : "Скопировать всё",systemImage:copied ? "checkmark" : "doc.on.doc") }
                    .accessibilityIdentifier("report-copy")
                ShareLink(item:text,subject:Text("Мой список АниПолки")) { Label("Поделиться текстом",systemImage:"square.and.arrow.up") }
            } footer: { Text("Для голосового чата с ИИ: выберите «Для ИИ», нажмите «Скопировать всё», вставьте текст в диалог и после этого включите голосовой режим.") }
        }.navigationTitle("Текст для копирования").navigationBarTitleDisplayMode(.inline)
    }

    private func count(_ status: WatchStatus) -> Int { store.snapshot.entries.filter { $0.status == status }.count }

    private func binding(_ status: WatchStatus) -> Binding<Bool> {
        Binding(get:{ options.statuses.contains(status) },set:{ if $0 { options.statuses.insert(status) } else { options.statuses.remove(status) } })
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        if store.snapshot.preferences.haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        Task { try? await Task.sleep(for:.seconds(2.5)); copied = false }
    }
}
