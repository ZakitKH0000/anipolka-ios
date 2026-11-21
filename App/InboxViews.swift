import SwiftUI

/// «5 мин назад», «3 ч назад», «вчера», «12 ноября».
func agoText(_ date: Date, now: Date = Date()) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "только что" }
    if minutes < 60 { return "\(minutes) мин назад" }
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "\(minutes / 60) ч назад" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "вчера" }
    let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"
    return f.string(from: date)
}

func titlesWord(_ n: Int) -> String {
    let tens = n % 100, ones = n % 10
    if (11...14).contains(tens) { return "тайтлов" }
    if ones == 1 { return "тайтл" }
    return (2...4).contains(ones) ? "тайтла" : "тайтлов"
}

private func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Сегодня" }
    if calendar.isDateInTomorrow(date) { return "Завтра" }
    let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "EE, d"
    return f.string(from: date).capitalized
}

/// «Выходы»: continue watching, new episodes grouped by title, the release calendar, catch-up plans and continuations.
struct ReleasesView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var assistant: ShelfAssistant
    @State private var confirmClear = false
    @State private var showAllRead = false
    @State private var day = 0
    private var notices: [(UUID, ReleaseNotice)] {
        store.snapshot.entries.flatMap { e in (e.releaseNotices ?? []).map { (e.id, $0) } }.sorted { $0.1.foundAt > $1.1.foundAt }
    }
    private func entry(_ id: UUID) -> Entry? { store.snapshot.entries.first { $0.id == id } }
    /// Why a title without unread notices still has something to watch.
    private func reason(_ e: Entry) -> String? {
        if let n = Backlog.available(e) { return "Доступно ещё \(n) \(episodesWord(n)) в источнике" }
        if let n = AniLibria.ahead(e) { return "В озвучке AniLibria: ещё \(n) \(episodesWord(n))" }
        if let n = Airing.aired(e) { return "Вышло и не просмотрено: \(n) \(episodesWord(n))" }
        return nil
    }

    var body: some View {
        let s = store.snapshot
        let all = notices
        let unread = all.filter { !$0.1.read }
        let read = all.filter { $0.1.read }
        // One row per title: its unread notices, newest title first.
        let grouped: [(Entry, [ReleaseNotice])] = Dictionary(grouping: unread, by: \.0).compactMap { id, list in entry(id).map { ($0, list.map(\.1).sorted { $0.episode < $1.episode }) } }
            .sorted { ($0.1.map(\.foundAt).max() ?? .distantPast) > ($1.1.map(\.foundAt).max() ?? .distantPast) }
        let groupedIDs = Set(grouped.map(\.0.id))
        let otherFresh = s.entries.filter { ($0.status == .watching || $0.status == .planned) && !groupedIDs.contains($0.id) && reason($0) != nil }
        let freshIDs = groupedIDs.union(otherFresh.map(\.id))
        let continuing = ReleasePlanner.continuing(s.entries, limit: 5).filter { !freshIDs.contains($0.id) }
        let plans = s.entries.compactMap { e in Franchise.catchUp(e, in: s).map { (e, $0) } }.prefix(3)
        let sequels = s.entries.compactMap { e in Airing.sequelSuggestion(e, in: s).map { (e, $0) } }
        let days = Airing.calendar(s.entries)
        List {
            if !grouped.isEmpty || !otherFresh.isEmpty {
                Section {
                    ForEach(grouped, id: \.0.id) { e, list in
                        GroupedNoticeRow(entry: e, notices: list)
                            .swipeActions(edge: .leading) { Button("Прочитано", systemImage: "envelope.open") { markAll(e.id, list) }.tint(.blue) }
                            .swipeActions(edge: .trailing) { Button("Удалить", systemImage: "trash", role: .destructive) { removeAll(e.id, list) } }
                    }
                    ForEach(otherFresh) { e in QuickRow(entry: e, detail: reason(e) ?? "") }
                } header: { Text("Новые серии · \(grouped.count + otherFresh.count)") } footer: {
                    Text("Несколько серий одного тайтла собраны в одну строку. Смахните вправо — прочитано, влево — удалить. Отметка «+1» сама убирает просмотренные серии.")
                }
            }

            if !continuing.isEmpty {
                Section("Продолжить") { ForEach(continuing) { e in QuickRow(entry: e, detail: "Следующая — серия \(e.seasonEpisode + 1)") } }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(days.enumerated()), id: \.offset) { index, d in
                            Button { day = index } label: {
                                VStack(spacing: 2) {
                                    Text(dayTitle(d.date)).font(.subheadline.weight(.semibold))
                                    Text(d.items.isEmpty ? "—" : "\(d.items.count) \(titlesWord(d.items.count))").font(.caption2).opacity(0.8)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(index == day ? Color.blue : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .foregroundStyle(index == day ? Color.white : Color.primary)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                let items = days.indices.contains(day) ? days[day].items : []
                if items.isEmpty { Text("В этот день ничего не отмечено").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    QuickRow(entry: item.entry, detail: calendarDetail(item), accent: item.at != nil)
                }
            } header: { Text(day == 0 ? "Сегодня выходит" : "Календарь выхода") }

            if !plans.isEmpty {
                Section("Догнать к выходу") {
                    ForEach(Array(plans), id: \.0.id) { e, plan in QuickRow(entry: e, detail: "До «\(plan.target)» \(plan.days) дн. · осталось \(plan.remaining) · по \(plan.perDay) в день") }
                }
            }

            if !sequels.isEmpty {
                Section("Продолжения") { ForEach(sequels, id: \.0.id) { e, hint in SequelRow(entry: e, hint: hint) } }
            }

            Section {
                Button { Task { await assistant.checkReleases(); await assistant.refreshAiring(force: true) } } label: {
                    HStack { Label("Проверить сейчас", systemImage: "arrow.clockwise"); if assistant.checking || assistant.refreshingAiring { Spacer(); ProgressView() } }
                }.disabled(assistant.checking).accessibilityIdentifier("check-releases")
                NavigationLink { WeekView() } label: { Label("Неделя: выходы и премьеры", systemImage: "calendar") }.accessibilityIdentifier("open-week")
                NavigationLink { DiagnosticsView() } label: { Label("Диагностика источников", systemImage: "stethoscope") }
                if let message = assistant.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if !assistant.sourcesReport.isEmpty { Text(assistant.sourcesReport).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("sources-report") }
            } footer: { Text("Фоновое обновление запускает iOS; при открытии приложения проверка запускается сама. Время из Shikimori и AniList — показ в Китае или Японии, озвучка обычно позже.") }

            if all.isEmpty && otherFresh.isEmpty {
                Section { ContentUnavailableView("Новые серии появятся здесь", systemImage: "play.rectangle.on.rectangle", description: Text("Откройте историю → «Источники новых серий» и выберите страницу, сезон и озвучку AniVibe.")) }
            }

            if !read.isEmpty {
                Section {
                    ForEach(showAllRead ? read : Array(read.prefix(5)), id: \.1.id) { entryID, notice in
                        if let e = entry(entryID) {
                            NoticeRow(entry: e, notice: notice)
                                .swipeActions { Button("Удалить", systemImage: "trash", role: .destructive) { _ = store.change { NoticeInbox.remove(&$0, entryID: entryID, noticeID: notice.id) } } }
                        }
                    }
                    if read.count > 5 { Button(showAllRead ? "Свернуть" : "Показать все (\(read.count))") { showAllRead.toggle() } }
                } header: { Text("Просмотренные") } footer: { Text("Просмотренные уведомления удаляются сами через \(NoticeInbox.keepReadDays) дней.") }
            }

        }
        .navigationTitle("Выходы").feedbackScreen("Выходы")
        .refreshable { await assistant.checkReleases(); await assistant.refreshAiring(force: true) }
        .toolbar {
            if !all.isEmpty {
                Menu {
                    if !unread.isEmpty { Button("Прочитать все (\(unread.count))", systemImage: "checkmark.circle") { _ = store.change { NoticeInbox.markAllRead(&$0) } } }
                    if !read.isEmpty { Button("Удалить просмотренные", systemImage: "trash") { _ = store.change { NoticeInbox.removeRead(&$0) } } }
                    Button("Удалить все уведомления", systemImage: "trash.slash", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Действия с уведомлениями").accessibilityIdentifier("notice-actions")
            }
        }
        .confirmationDialog("Удалить все уведомления?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { _ = store.change { NoticeInbox.removeAll(&$0) } }
        } message: { Text("Список найденных серий очистится. Прогресс, источники и коллекция не изменятся; новые серии продолжат появляться.") }
    }
    private func calendarDetail(_ item: CalendarItem) -> String {
        guard let at = item.at else { return "По вашему расписанию · следующая \(item.entry.seasonEpisode + 1)" }
        var parts: [String] = []
        if let episode = item.episode { parts.append("Серия \(episode)") }
        parts.append(at.formatted(date: .omitted, time: .shortened))
        parts.append(Airing.countdown(at))
        return parts.joined(separator: " · ")
    }
    private func markAll(_ id: UUID, _ list: [ReleaseNotice]) {
        _ = store.change { s in for n in list { NoticeInbox.markRead(&s, entryID: id, noticeID: n.id) } }
    }
    private func removeAll(_ id: UUID, _ list: [ReleaseNotice]) {
        _ = store.change { s in for n in list { NoticeInbox.remove(&s, entryID: id, noticeID: n.id) } }
    }
}

/// All unread episodes of one title in one row: «Серии 32–34 · 3 новых», the dub and when it was found.
struct GroupedNoticeRow: View {
    let entry: Entry
    let notices: [ReleaseNotice]
    @EnvironmentObject var store: ShelfStore
    @Environment(\.openURL) private var openURL
    @AppStorage(Lab.inAppPlayer) private var inAppPlayer = true
    @State private var watching: Int?
    var body: some View {
        let first = notices.first, last = notices.last
        HStack(spacing: 14) {
            NavigationLink { EntryDetail(id: entry.id) } label: {
                HStack(spacing: 14) {
                    CoverView(data: entry.coverData, url: entry.coverURL, entryID: entry.id).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topLeading) { Circle().fill(.blue).frame(width: 12, height: 12).overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)).offset(x: -5, y: -5).accessibilityLabel("Не прочитано") }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let first, let last {
                            Text(first.episode == last.episode ? "Серия \(last.episode)" : "Серии \(first.episode)–\(last.episode) · +\(notices.count)").font(.subheadline).lineLimit(1)
                            Text([last.sourceLabel, agoText(last.foundAt)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }.accessibilityIdentifier("release-entry")
            Button { watch() } label: { Image(systemName: "play.circle.fill").font(.title) }.buttonStyle(.borderless).accessibilityLabel("Смотреть").accessibilityIdentifier("watch-notice")
        }
        .fullScreenCover(item: Binding(get: { watching.map { WatchEpisode(number: $0) } }, set: { watching = $0?.number })) { item in
            WatchView(entryID: entry.id, episode: item.number).environmentObject(store)
        }
    }
    /// Starts from the first episode not yet watched; the site opens outside when built-in viewing is off.
    private func watch() {
        let next = max(entry.seasonEpisode + 1, notices.first?.episode ?? entry.seasonEpisode + 1)
        if inAppPlayer, WatchTarget.url(for: entry, episode: next) != nil { watching = next }
        else if let notice = notices.first(where: { $0.episode >= next }) ?? notices.last, let url = validWebURL(notice.url) { openURL(url) }
    }
}

/// One found episode: cover, title, episode, dub and time; tapping opens the card and marks it read.
struct NoticeRow: View {
    let entry: Entry
    let notice: ReleaseNotice
    @EnvironmentObject var store: ShelfStore
    @Environment(\.openURL) private var openURL
    var body: some View {
        HStack(spacing: 14) {
            NavigationLink { EntryDetail(id: entry.id).onAppear { markRead() } } label: {
                HStack(spacing: 14) {
                    CoverView(data: entry.coverData, url: entry.coverURL, entryID: entry.id).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .topLeading) { if !notice.read { Circle().fill(.blue).frame(width: 12, height: 12).overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)).offset(x: -5, y: -5).accessibilityLabel("Не прочитано") } }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.weight(notice.read ? .regular : .semibold)).lineLimit(1)
                        let jump = notice.episode - notice.previousEpisode
                        Text("Серия \(notice.episode)" + (jump > 1 ? " (+\(jump))" : "")).font(.subheadline).foregroundStyle(notice.read ? Color.secondary : Color.primary)
                        Text([notice.sourceLabel, agoText(notice.foundAt)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.accessibilityIdentifier("release-entry")
            if let url = validWebURL(notice.url) {
                Button { markRead(); openURL(url) } label: { Image(systemName: "arrow.up.right.circle").font(.title2) }.buttonStyle(.borderless).accessibilityLabel("Открыть на сайте").accessibilityIdentifier("watch-notice")
            }
        }
    }
    private func markRead() {
        guard !notice.read else { return }
        _ = store.change { NoticeInbox.markRead(&$0, entryID: entry.id, noticeID: notice.id) }
    }
}

/// «Вышло продолжение»: the next season with Add and Hide.
struct SequelRow: View {
    let entry: Entry
    let hint: SequelHint
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        HStack(spacing: 14) {
            CoverView(data: nil, url: hint.coverURL, entryID: nil).frame(width: 52, height: 74).clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(Airing.sequelLabel(hint)).font(.caption.weight(.semibold)).foregroundStyle(hint.status == Airing.anons ? Color.orange : Color.green)
                Text(hint.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("после «\(entry.title)»").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Button("Добавить на потом") { _ = store.change { $0.entries.insert(Airing.sequelEntry(hint, after: entry.id), at: 0) } }.buttonStyle(.borderedProminent)
                    Button("Скрыть") { _ = store.change { s in if let i = s.entries.firstIndex(where: { $0.id == entry.id }) { s.entries[i].dismissedSequelID = hint.id } } }.buttonStyle(.bordered)
                }.controlSize(.small).padding(.top, 4)
            }
        }.padding(.vertical, 4)
    }
}

/// Broadcast block on the title card: next episode with countdown, aired count, unwatched episodes.
struct AiringCard: View {
    let entry: Entry
    var body: some View {
        if let info = entry.airing {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let at = Airing.upcoming(entry, now: context.date)
                VStack(alignment: .leading, spacing: 6) {
                    Label(at.map { "Серия \(Airing.nextEpisode(entry, now: context.date) ?? 0) · \(Airing.countdown($0, now: context.date))" } ?? Airing.progressText(info), systemImage: "clock")
                        .font(.headline).foregroundStyle(at == nil ? Color.primary : Color.orange)
                    if let at { Text(Airing.moment(at, now: context.date).capitalizedFirst + " · " + Airing.progressText(info).lowercased()).font(.subheadline).foregroundStyle(.secondary) }
                    if let n = Airing.aired(entry) { Text("Уже вышло и не просмотрено: \(n) \(episodesWord(n))").font(.subheadline.bold()).foregroundStyle(.tint) }
                    if let libria = info.libria {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").foregroundStyle(.orange)
                            Text(libriaLine(libria)).font(.subheadline)
                            Spacer(minLength: 4)
                            if let url = URL(string: libria.url) { Link("Открыть", destination: url).font(.subheadline.weight(.semibold)) }
                        }
                    }
                    Text("Shikimori · время оригинального показа; озвучка обычно выходит позже. Обновлено \(agoText(info.checkedAt)).").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }
}

private func libriaLine(_ l: LibriaInfo) -> String {
    var parts: [String] = []
    if let p = l.publishedEpisode { parts.append("AniLibria: озвучена серия \(p)") } else { parts.append("AniLibria озвучивает") }
    if let n = l.nextEpisode, let day = l.weekday { parts.append("\(n)-я — \(["вс", "пн", "вт", "ср", "чт", "пт", "сб"][day - 1])") }
    return parts.joined(separator: " · ")
}

/// Small countdown chip on a cover: «⏱ 2 д».
struct CountdownChip: View {
    let at: Date
    var body: some View {
        Label(Airing.shortCountdown(at), systemImage: "clock").font(.caption.bold()).labelStyle(.titleAndIcon)
            .padding(.horizontal, 8).padding(.vertical, 4).background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
