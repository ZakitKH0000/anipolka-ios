import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }; self.data = data }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct SettingsView: View {
    @EnvironmentObject var store: ShelfStore
    @State private var showTextImport = false
    @State private var exportDocument: BackupDocument?
    @State private var showExport = false
    @State private var showRestore = false
    @State private var backup: Snapshot?
    @State private var confirmingReplace = false
    @State private var busy = false
    @State private var notice: String?
    @State private var showReorder = false
    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема",selection:store.preference(\.theme)) { ForEach(Theme.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("theme")
                Picker("Вид коллекции",selection:store.preference(\.layout)) { ForEach(Layout.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Picker("Сортировка",selection:store.preference(\.sort)) { ForEach(ShelfSort.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Button("Ручной порядок") { showReorder = true }
                Toggle("Продолжить просмотр",isOn:store.preference(\.showContinue))
            }
            Section("Отклик и сеть") {
                Toggle("Тактильный отклик при +1",isOn:store.preference(\.haptics))
                Toggle("Обложки только через Wi-Fi",isOn:store.preference(\.wifiOnly)).accessibilityIdentifier("wifi-only")
            } footer: { Text("Сохранённые обложки доступны офлайн. Ограничение Wi-Fi действует на все загружаемые изображения, в том числе результаты поиска. Поиск названий использует любую сеть.") }
            Section("Перенос и резервная копия") {
                Button("Импорт текстового списка",systemImage:"text.badge.plus") { showTextImport = true }.accessibilityIdentifier("text-import")
                Button("Сохранить копию в Файлы",systemImage:"square.and.arrow.up") { export() }.disabled(busy || store.loadFailure != nil)
                Button("Восстановить из Файлов",systemImage:"square.and.arrow.down") { showRestore = true }.disabled(busy)
                if busy { ProgressView("Подготовка данных…") }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Копия содержит коллекцию, прогресс, порядок, настройки и уже сохранённые обложки. После выбора файла вы увидите предпросмотр восстановления. До подтверждения ничего не изменяется.") }
            Section("Об АниПолке") {
                Label("АниПолка 1.0",systemImage:"books.vertical.fill")
                Text("Разработчик — Закир Халилов").font(.subheadline)
                Text("Создано для личного использования.").font(.footnote).foregroundStyle(.secondary)
                Link("Каталог и изображения: Shikimori",destination:URL(string:"https://shikimori.io")!)
                Text("Коллекция хранится на iPhone. Без аккаунтов, рекламы и аналитики. В каталог отправляется только введённый поисковый запрос. При открытии ссылки используется выбранный вами сайт.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Настройки")
            .sheet(isPresented:$showTextImport) { TextImportView() }
            .sheet(isPresented:$showReorder) { ReorderView() }
            .fileExporter(isPresented:$showExport,document:exportDocument,contentType:.json,defaultFilename:"АниПолка-\(Date().formatted(.iso8601.year().month().day()))") { result in
                if case .success = result { notice = "Резервная копия сохранена." }
                if case .failure(let error) = result { notice = "Копия не сохранена: \(error.localizedDescription)" }
            }
            .fileImporter(isPresented:$showRestore,allowedContentTypes:[.json]) { result in
                switch result {
                case .success(let url): readBackup(url)
                case .failure(let error): notice = error.localizedDescription
                }
            }
            .sheet(isPresented:Binding(get:{backup != nil},set:{if !$0 {backup = nil}})) {
                NavigationStack {
                    if let copy = backup {
                        List {
                            Section("Проверенная копия") {
                                LabeledContent("Произведений",value:"\(copy.entries.count)")
                                LabeledContent("Сохранённых обложек",value:"\(copy.entries.filter { $0.coverData != nil }.count)")
                                Text("В вашей коллекции сейчас: \(store.snapshot.entries.count)").foregroundStyle(.secondary)
                            }
                            Section {
                                Button("Объединить с текущей коллекцией") { if store.restore(copy,replacing:false) { backup = nil; notice = "Коллекции объединены." } }.disabled(store.loadFailure != nil)
                                Text("Добавятся записи с новыми идентификаторами. Уже существующие записи и текущие настройки сохранятся. Одинаковые названия с разными идентификаторами останутся отдельными.").font(.caption).foregroundStyle(.secondary)
                                Button("Заменить коллекцию и настройки",role:.destructive) { confirmingReplace = true }
                            }
                            Section("Содержимое") { ForEach(copy.entries) { e in VStack(alignment:.leading) { Text(e.title); Text(e.subtitle).font(.caption).foregroundStyle(.secondary) } } }
                        }.navigationTitle("Восстановление").navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("Отмена") { backup = nil } }
                            .alert("Заменить текущую коллекцию?",isPresented:$confirmingReplace) {
                                Button("Заменить",role:.destructive) { if store.restore(copy,replacing:true) { backup = nil; notice = "Коллекция восстановлена вместе с настройками." } }
                                Button("Отмена",role:.cancel) {}
                            } message: { Text("Текущий прогресс будет заменён данными выбранной копии. Перед заменой желательно сохранить отдельную копию.") }
                    }
                }
            }
    }
    private func export() {
        busy = true; notice = nil
        let snapshot = store.snapshot
        Task {
            do { let data = try await Task.detached(priority:.userInitiated) { try snapshot.encoded() }.value; exportDocument = BackupDocument(data:data); showExport = true }
            catch { notice = error.localizedDescription }; busy = false
        }
    }
    private func readBackup(_ url: URL) {
        busy = true; notice = nil
        Task {
            do {
                backup = try await Task.detached(priority:.userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size <= 150_000_000 else { throw ShelfError.invalid("Файл больше 150 МБ.") }
                    return try Snapshot.decode(Data(contentsOf:url))
                }.value
            } catch { notice = "Восстановление не выполнено: \(error.localizedDescription)" }; busy = false
        }
    }
}
struct TextImportView: View {
    @EnvironmentObject var store: ShelfStore
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var rows: [ImportRow] = []
    @State private var reviewing = false
    @State private var chooseFile = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Group {
                if reviewing { review }
                else {
                    Form {
                        Section {
                            Text("Одна история на строку: название, пробел и последняя просмотренная серия. Например: «Путь к вершине 24». Названия с опечатками сохраняются как написаны.").font(.subheadline).foregroundStyle(.secondary)
                            TextEditor(text:$text).frame(minHeight:240).accessibilityIdentifier("import-text")
                            Button("Открыть текстовый файл",systemImage:"doc.text") { chooseFile = true }
                            Button("Проверить список") { prepare() }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("preview-import")
                        } footer: { Text("Текст обрабатывается на устройстве. Ничего не отправляется в каталог. Обложку можно найти после импорта в карточке каждой истории.") }
                    }
                }
            }.navigationTitle(reviewing ? "Проверка списка" : "Перенос списка").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button(reviewing ? "Назад" : "Отмена") { if reviewing { reviewing = false } else { dismiss() } } } }
                .fileImporter(isPresented:$chooseFile,allowedContentTypes:[.plainText,.text]) { result in
                    do {
                        let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw ShelfError.invalid("Текстовый файл больше 1 МБ.") }
                        let data = try Data(contentsOf:url)
                        guard let decoded = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else { throw ShelfError.invalid("Сохраните файл в кодировке UTF-8.") }; text = decoded
                    } catch { message = error.localizedDescription }
                }
                .alert("Импорт списка",isPresented:Binding(get:{message != nil},set:{if !$0 {message = nil}})) { Button("Понятно",role:.cancel) {} } message: { Text(message ?? "") }
        }
    }
    private var review: some View {
        List {
            Section { Text("Проверьте названия и номера. Нераспознанные строки сохраняют исходное название с серией 0. Совпадающие с коллекцией названия по умолчанию не выбраны.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach($rows) { $row in
                Section {
                    Toggle("Добавить запись",isOn:$row.included)
                    TextField("Название",text:$row.title,axis:.vertical)
                    HStack { Text("Последняя серия"); Spacer(); TextField("0",value:$row.episode,format:.number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    Toggle("Избранное",isOn:$row.favorite)
                    if !row.recognized { Label("Номер не распознан — проверьте",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Text("Исходная строка: \(row.original)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section { Button("Добавить выбранные: \(rows.filter(\.included).count)") { apply() }.disabled(rows.allSatisfy { !$0.included }).accessibilityIdentifier("apply-import") }
        }.scrollDismissesKeyboard(.interactively)
    }
    private func prepare() {
        guard text.utf8.count <= 1_000_000 else { message = "Список больше 1 МБ."; return }
        rows = TextListParser.parse(text)
        guard rows.count <= 2000 else { message = "За один раз можно перенести не более 2000 записей."; return }
        let names = Set(store.snapshot.entries.map { $0.title.lowercased() })
        for i in rows.indices { if names.contains(rows[i].title.lowercased()) { rows[i].included = false } }
        reviewing = true
    }
    private func apply() {
        let imported = rows.filter(\.included).map(\.entry)
        if store.change({ $0.entries += imported }) { dismiss() }
        else { message = store.error; store.error = nil }
    }
}
