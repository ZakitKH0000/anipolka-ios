import SwiftUI

struct SearchView: View {
    var selectingCover = false
    var initialQuery = ""
    let onSaved: (AnimeCandidate?) -> Void
    @EnvironmentObject var network: NetworkService
    @State private var query = ""
    @State private var results: [AnimeCandidate] = []
    @State private var loading = false
    @State private var message: String?
    @State private var pending: Task<Void, Never>?
    @State private var editor: Entry?
    @State private var selected: AnimeCandidate?
    @State private var searched = false
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Название на русском или оригинале",text:$query).submitLabel(.search).onSubmit { search() }.accessibilityIdentifier("catalog-query")
                    if loading { ProgressView() }
                }
                Button("Искать в каталоге") { search() }.disabled(query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || loading).accessibilityIdentifier("catalog-search")
            } footer: { Text("Поиск Shikimori. Сверьте обложку, год и название: похожие произведения и сезоны показаны отдельно.") }
            if !network.canLoadCovers && network.wifiOnly { Section { Label("Обложки загрузятся при подключении к Wi-Fi. Поиск названий доступен через любую сеть.",systemImage:"wifi") } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if searched && !loading && results.isEmpty && message == nil { Section { Text("Совпадений нет. Попробуйте короткое или оригинальное название либо добавьте запись вручную.") } }
            ForEach(results) { candidate in
                Button { choose(candidate) } label: {
                    HStack(alignment:.top,spacing:14) {
                        CoverView(data:nil,url:candidate.previewURL).frame(width:72,height:100).clipShape(RoundedRectangle(cornerRadius:12))
                        VStack(alignment:.leading,spacing:6) {
                            Text(candidate.title).font(.headline).foregroundStyle(.primary)
                            Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                            Text(selectingCover ? "Выбрать произведение и обложку" : "Выбрать и добавить").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                        }
                    }.padding(.vertical,4)
                }.buttonStyle(.plain)
            }
            if !selectingCover {
                Section {
                    Button("Добавить вручную",systemImage:"square.and.pencil") { editor = Entry(title:query) }.accessibilityIdentifier("manual-add")
                } footer: { Text("Вручную можно сохранить привычное название, сквозной номер серии и свою обложку. Каталог не содержит все дунхуа и варианты перевода.") }
            }
            Section { Link("Открыть Shikimori",destination:URL(string:"https://shikimori.io")!) }.font(.footnote)
        }
        .navigationTitle(selectingCover ? "Найти обложку" : "Добавить историю").navigationBarTitleDisplayMode(.inline)
        .onAppear { if query.isEmpty { query = initialQuery } }
        .onDisappear { pending?.cancel(); loading = false }
        .sheet(item:$editor) { entry in EntryEditor(entry:entry) { onSaved(selected) } }
    }
    private func choose(_ candidate: AnimeCandidate) {
        if selectingCover { onSaved(candidate); return }
        selected = candidate
        var e = Entry(title:candidate.title); e.originalTitle = candidate.name; e.sourceID = candidate.id; e.sourceURL = candidate.pageURL; e.coverURL = candidate.posterURL
        editor = e
    }
    private func search() {
        let term = query.trimmingCharacters(in:.whitespacesAndNewlines); guard !term.isEmpty else { return }
        pending?.cancel(); loading = true; message = nil; results = []; searched = true
        pending = Task {
            do { let found = try await network.search(term); try Task.checkCancellation(); results = found }
            catch is CancellationError { return }
            catch { if !Task.isCancelled { message = "Не удалось выполнить поиск. \(error.localizedDescription)" } }
            if !Task.isCancelled { loading = false }
        }
    }
}
