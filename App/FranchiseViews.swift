import SwiftUI

/// Season tabs of a franchise: one pill per part, in broadcast order. Parts not in the collection can be added.
struct FranchiseSeasonsStrip: View {
    let entry: Entry
    let onSelect: (UUID) -> Void
    @EnvironmentObject var store: ShelfStore
    @State private var adding: FranchisePart?
    var body: some View {
        if let info = Franchise.info(entry, in: store.snapshot) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(info.parts) { part in
                            let owned = store.snapshot.entries.first { $0.sourceID == part.id }
                            let selected = part.id == entry.sourceID
                            Button {
                                if let owned { onSelect(owned.id) } else { adding = part }
                            } label: {
                                HStack(spacing: 5) {
                                    if owned?.status == .completed { Image(systemName: "checkmark.circle.fill").font(.caption) }
                                    else if owned == nil { Image(systemName: "plus.circle").font(.caption) }
                                    Text(Franchise.label(part, in: info)).font(.subheadline.weight(.semibold))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.secondary.opacity(owned == nil ? 0.08 : 0.18)), in: Capsule())
                                .foregroundStyle(selected ? Color.white : (owned == nil ? Color.secondary : Color.primary))
                            }
                            .buttonStyle(.plain).id(part.id)
                            .accessibilityLabel(Franchise.label(part, in: info) + ": " + part.title + (owned == nil ? ", не в коллекции" : ""))
                        }
                    }.padding(.vertical, 2)
                }
                .onAppear { if let id = entry.sourceID { proxy.scrollTo(id, anchor: .center) } }
            }
            .confirmationDialog(adding.map { "Добавить «\($0.title)»?" } ?? "", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }), titleVisibility: .visible) {
                if let part = adding {
                    Button("Добавить и смотреть") { add(part, info: info, status: .watching) }
                    Button("Добавить на потом") { add(part, info: info, status: .planned) }
                }
            } message: { Text("Часть появится в этой же карточке франшизы.") }
        }
    }
    private func add(_ part: FranchisePart, info: FranchiseInfo, status: WatchStatus) {
        let created = Franchise.entry(for: part, after: entry, in: info, status: status)
        if store.change({ $0.entries.insert(created, at: 0) }) { onSelect(created.id) }
        adding = nil
    }
}

/// Franchise card: progress through all parts, numbering mode and where this season starts.
struct FranchiseSection: View {
    let entry: Entry
    let onSelect: (UUID) -> Void
    @EnvironmentObject var store: ShelfStore
    @State private var editingOffset = false
    @State private var offsetText = ""
    var body: some View {
        if let info = Franchise.info(entry, in: store.snapshot) {
            let owned = info.parts.compactMap { p in store.snapshot.entries.first { $0.sourceID == p.id } }
            let done = owned.filter { $0.status == .completed }.count
            let mainParts = info.parts.filter(Franchise.isMain)
            let watched = owned.reduce(0) { $0 + $1.seasonEpisode }
            let total = mainParts.reduce(0) { $0 + ($1.episodes ?? 0) }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Франшиза · \(info.parts.count) \(partsWord(info.parts.count))", systemImage: "square.stack.3d.up.fill").font(.headline)
                    Spacer()
                    Text("досмотрено \(done)").font(.subheadline).foregroundStyle(.secondary)
                }
                if total > 0 {
                    ProgressView(value: Double(min(watched, total)), total: Double(total)).tint(.accentColor)
                    Text("Основные сезоны: \(min(watched, total)) из \(total) серий").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(info.parts) { part in
                    let e = store.snapshot.entries.first { $0.sourceID == part.id }
                    Button { if let e { onSelect(e.id) } } label: {
                        HStack(spacing: 12) {
                            CoverView(data: e?.coverData, url: e?.coverURL ?? part.coverURL, entryID: e?.id).frame(width: 34, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.title).font(.subheadline.weight(part.id == entry.sourceID ? .bold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(partLine(part, entry: e, info: info)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if e?.status == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else if e != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }.buttonStyle(.plain).disabled(e == nil)
                }
                Divider()
                Toggle("Сквозная нумерация", isOn: Binding(get: { info.absolute == true }, set: { value in _ = store.change { Franchise.setAbsolute(&$0, key: info.key, absolute: value) } }))
                    .font(.subheadline).accessibilityIdentifier("franchise-absolute")
                if info.absolute == true {
                    Button {
                        offsetText = String(entry.episodeOffset ?? 0); editingOffset = true
                    } label: {
                        Text("Этот сезон начинается с серии \((entry.episodeOffset ?? 0) + 1) · изменить").font(.footnote)
                    }
                    Text("Серия \(entry.episode) по сквозному счёту = серия \(entry.seasonEpisode) этого сезона. Сайты и Shikimori считают внутри сезона.").font(.caption).foregroundStyle(.secondary)
                } else if let part = Franchise.part(entry, in: info), Franchise.countsThroughSeasons(entry, part: part), let total = part.episodes {
                    Text("Серия \(entry.episode) больше, чем серий в этом сезоне (\(total)). Похоже, вы считаете через все сезоны — включите «Сквозную нумерацию»: номер 200 сохранится, а приложение посчитает серию внутри сезона.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Сейчас серии считаются внутри каждого сезона, как на Shikimori и AniVibe. Включите, если вы привыкли к одному номеру через все сезоны.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .alert("Сколько серий до этого сезона?", isPresented: $editingOffset) {
                TextField("Например, 168", text: $offsetText).keyboardType(.numberPad)
                Button("Сохранить") { if let value = Int(offsetText) { _ = store.change { Franchise.setOffset(&$0, entryID: entry.id, offset: value) } } }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Номер этого сезона по вашему счёту будет начинаться со следующей серии.") }
        }
    }
    private func partLine(_ part: FranchisePart, entry e: Entry?, info: FranchiseInfo) -> String {
        var items = [Franchise.label(part, in: info)]
        if let year = part.airedOn?.prefix(4) { items.append(String(year)) }
        if let e { items.append(e.status == .completed ? "досмотрено" : "серия \(e.seasonEpisode)" + (part.episodes.map { " из \($0)" } ?? "")) }
        else { items.append(part.status == Airing.anons ? "анонс" : (part.episodes.map { "\($0) \(episodesWord($0))" } ?? "нет в коллекции")) }
        return items.joined(separator: " · ")
    }
    private func partsWord(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "частей" }
        if ones == 1 { return "часть" }
        return (2...4).contains(ones) ? "части" : "частей"
    }
}

/// «У вас сезон 3, а привязан сезон 1 — привязать к нужному?»
struct SeasonMismatchCard: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    var body: some View {
        if let part = Franchise.seasonMismatch(entry, in: store.snapshot), let season = entry.season {
            VStack(alignment: .leading, spacing: 10) {
                Label("Сезон \(season) или другой?", systemImage: "exclamationmark.arrow.triangle.2.circlepath").font(.headline).foregroundStyle(.orange)
                Text("В записи указан сезон \(season), а по названию она связана с другой частью. Сезон \(season) в каталоге — «\(part.title)».").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Привязать к сезону \(season)") {
                        if store.change({ Franchise.rebind(&$0, entryID: entry.id, to: part) }) { Task { await assistant.refreshAiring(force: true); assistant.queueCovers(force: true) } }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("rebind-season")
                }.controlSize(.small)
                Text("Название, прогресс и заметки не изменятся; обновятся обложка, даты выхода и вкладки сезонов.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// The number runs past the season the entry is bound to: offer to move it to the right season.
struct SeasonOverflowCard: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    var body: some View {
        if let over = Franchise.overflow(entry, in: store.snapshot) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Вы уже на \(over.season) сезоне", systemImage: "arrow.forward.circle.fill").font(.headline).foregroundStyle(.orange)
                Text("Серия \(entry.episode) по вашей нумерации — это сезон \(over.season), серия \(over.episode) («\(over.part.title)»).").font(.subheadline).foregroundStyle(.secondary)
                Button("Перейти на сезон \(over.season)") {
                    if store.change({ Franchise.move(&$0, entryID: entry.id, to: over) }) { Task { await assistant.refreshAiring(force: true); assistant.queueCovers(force: true) } }
                }.buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("move-season")
                Text("Ваша общая нумерация (серия \(entry.episode)) останется; обновятся обложка, даты выхода и вкладки сезонов.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// «Сезон досмотрен — начать следующий?»
struct NextSeasonCard: View {
    let entry: Entry
    let onSelect: (UUID) -> Void
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        if let next = Franchise.nextSeasonPrompt(entry, in: store.snapshot) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Сезон досмотрен", systemImage: "party.popper.fill").font(.headline).foregroundStyle(.green)
                HStack(spacing: 12) {
                    CoverView(data: nil, url: next.coverURL).frame(width: 46, height: 66).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Дальше: \(next.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(next.episodes.map { "\($0) \(episodesWord($0))" } ?? "Число серий пока неизвестно").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Начать следующий сезон") {
                        var newID: UUID?
                        if store.change({ newID = Franchise.startNext(&$0, from: entry.id, next: next) }), let newID { onSelect(newID) }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("start-next-season")
                    Button("Позже") { _ = store.change { s in if let i = s.entries.firstIndex(where: { $0.id == entry.id }) { s.entries[i].dismissedSequelID = next.id } } }.buttonStyle(.bordered)
                }.controlSize(.small)
                Text("Текущий сезон станет «Завершено». Источник AniVibe для нового сезона можно выбрать в его карточке.").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// «Догнать к выходу»: episodes per day to finish before the next part premieres.
struct CatchUpCard: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        if let plan = Franchise.catchUp(entry, in: store.snapshot) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.run").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Догнать к выходу").font(.headline)
                    Text("До «\(plan.target)» \(plan.days) \(daysWord(plan.days)). Осталось \(plan.remaining) \(episodesWord(plan.remaining)) — смотрите по \(plan.perDay) в день.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
    private func daysWord(_ n: Int) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return "дней" }
        if ones == 1 { return "день" }
        return (2...4).contains(ones) ? "дня" : "дней"
    }
}

/// «Сезон 3 из 5» on a cover that stands for a whole franchise.
struct FranchiseBadge: View {
    let entry: Entry
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        if store.snapshot.preferences.groupFranchises, let info = Franchise.info(entry, in: store.snapshot),
           Franchise.members(entry, in: store.snapshot).count > 1, let part = Franchise.part(entry, in: info) {
            Label("\(Franchise.label(part, in: info)) · \(info.parts.filter(Franchise.isMain).count)", systemImage: "square.stack.3d.up.fill")
                .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
        }
    }
}
