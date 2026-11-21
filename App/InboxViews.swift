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

/// The new-episode inbox, the release calendar and continuations.
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

    var body: some View {
        let all = notices
        let fresh = all.filter { !$0.1.read }
        let read = all.filter { $0.1.read }
        let sequels = store.snapshot.entries.compactMap { e in Airing.sequelSuggestion(e, in: store.snapshot).map { (e, $0) } }
        let days = Airing.calendar(store.snapshot.entries)
        List {
            if !fresh.isEmpty {
                Section {
                    ForEach(fresh, id: \.1.id) { entryID, notice in
                        if let e = entry(entryID) {
                            NoticeRow(entry: e, notice: notice)
                                .swipeActions(edge: .leading) { Button("Прочитано", systemImage: "envelope.open") { _ = store.change { NoticeInbox.markRead(&$0, entryID: entryID, noticeID: notice.id) } }.tint(.blue) }
                                .swipeActions(edge: .trailing) { Button("Удалить", systemImage: "trash", role: .destructive) { _ = store.change { NoticeInbox.remove(&$0, entryID: entryID, noticeID: notice.id) } } }
                        }
                    }
                } header: { Text("Новые · \(fresh.count)") } footer: { Text("Смахните вправо — прочитано, влево — удалить. Отметка «+1» в карточке сама убирает серии, которые вы посмотрели.") }
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
                    NavigationLink { EntryDetail(id: item.entry.id) } label: {
                        HStack(spacing: 14) {
                            CoverView(data: item.entry.coverData, url: item.entry.coverURL, entryID: item.entry.id).frame(width: 44, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.entry.title).font(.headline).lineLimit(2)
                                if let at = item.at {
                                    Text([item.episode.map { "Серия \($0)" }, at.formatted(date: .omitted, time: .shortened), Airing.countdown(at)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.orange)
                                } else {
                                    Text("По вашему расписанию · следующая \(item.entry.episode + 1)").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: { Text("Календарь выхода") }

            if !sequels.isEmpty {
                Section("Продолжения") {
                    ForEach(sequels, id: \.0.id) { e, hint in SequelRow(entry: e, hint: hint) }
                }
            }

            Section {
                Button { Task { await assistant.checkReleases(); await assistant.refreshAiring(force: true) } } label: {
                    HStack { Label("Проверить сейчас", systemImage: "arrow.clockwise"); if assistant.checking { Spacer(); ProgressView() } }
                }.disabled(assistant.checking).accessibilityIdentifier("check-releases")
                NavigationLink { WeekView() } label: { Label("Неделя: выходы и премьеры", systemImage: "calendar") }.accessibilityIdentifier("open-week")
                if let message = assistant.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Фоновое обновление запускает iOS. Даты выхода берутся из Shikimori: это время показа в Японии или Китае, озвучка обычно выходит позже.") }

            if all.isEmpty {
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

            let connected = store.snapshot.entries.filter { !($0.subscriptions ?? []).isEmpty }
            if !connected.isEmpty {
                Section("Подключённые истории") {
                    ForEach(connected) { entry in
                        NavigationLink { EntryDetail(id: entry.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title)
                                Text("Источников: \((entry.subscriptions ?? []).count)").font(.caption).foregroundStyle(.secondary)
                                if (entry.subscriptions ?? []).contains(where: { $0.error != nil }) { Label("Есть недоступный источник", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Новые серии").feedbackScreen("Серии")
        .refreshable { await assistant.checkReleases(); await assistant.refreshAiring(force: true) }
        .toolbar {
            if !all.isEmpty {
                Menu {
                    if !fresh.isEmpty { Button("Прочитать все (\(fresh.count))", systemImage: "checkmark.circle") { _ = store.change { NoticeInbox.markAllRead(&$0) } } }
                    if !read.isEmpty { Button("Удалить просмотренные", systemImage: "trash") { _ = store.change { NoticeInbox.removeRead(&$0) } } }
                    Button("Удалить все уведомления", systemImage: "trash.slash", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Действия с уведомлениями").accessibilityIdentifier("notice-actions")
            }
        }
        .confirmationDialog("Удалить все уведомления?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { _ = store.change { NoticeInbox.removeAll(&$0) } }
        } message: { Text("Список найденных серий очистится. Прогресс, источники и коллекция не изменятся; новые серии продолжат появляться.") }
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
                Button("Смотреть") { markRead(); openURL(url) }.buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("watch-notice")
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
                    Text("Shikimori · время оригинального показа; озвучка обычно выходит позже. Обновлено \(agoText(info.checkedAt)).").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }
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
