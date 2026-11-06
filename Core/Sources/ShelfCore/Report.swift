import Foundation

/// What goes into the text the user copies out of the app.
public struct ReportOptions: Equatable {
    public enum Style: String, CaseIterable, Identifiable {
        case brief = "Кратко", detailed = "Подробно", forAI = "Для ИИ"
        public var id: String { rawValue }
    }
    public var style: Style = .detailed
    public var statuses: Set<WatchStatus> = Set(WatchStatus.allCases)
    /// «Где остановился» and the free-form note.
    public var notes = true
    public var links = false
    public var statistics = true
    public init() {}
}

/// A plain-text copy of the collection: titles, progress, sources and totals.
/// Everything comes from the local file; nothing is sent anywhere.
public enum ShelfReport {
    public static func text(_ snapshot: Snapshot, options: ReportOptions = ReportOptions(), now: Date = Date(), calendar: Calendar = .current) -> String {
        var blocks: [String] = []
        if options.style == .forAI { blocks.append(aiHeader(now: now, calendar: calendar)) }
        let separator = options.style == .detailed ? "\n\n" : "\n"
        let groups = WatchStatus.allCases.filter { options.statuses.contains($0) }.compactMap { status -> String? in
            let entries = snapshot.visible(status: status)
            guard !entries.isEmpty else { return nil }
            return "\(status.rawValue) (\(entries.count)):\n" + entries.map { block($0, options: options, now: now, calendar: calendar) }.joined(separator: separator)
        }
        blocks.append(groups.isEmpty ? "Список пуст или ничего не выбрано." : groups.joined(separator: "\n\n"))
        if options.statistics { blocks.append(statistics(snapshot, now: now, calendar: calendar)) }
        if options.style == .forAI { blocks.append("Мой вопрос: ") }
        return blocks.joined(separator: "\n\n")
    }

    static func aiHeader(now: Date, calendar: Calendar) -> String {
        "Это мой личный список аниме и дунхуа из приложения АниПолка на \(date(now, calendar: calendar)).\n"
        + "Как читать: «остановился на серии N» — последняя серия, которую я посмотрел (нумерация моя, иногда сквозная); «просмотрено: 1–N» — я смотрел подряд до серии N; «Источники» — озвучки, которые я отслеживаю, и последняя доступная в них серия.\n"
        + "Опирайся только на эти данные и прямо говори, если чего-то не знаешь."
    }

    /// One title: a single line in the brief style, a few lines otherwise.
    static func block(_ entry: Entry, options: ReportOptions, now: Date, calendar: Calendar) -> String {
        if options.style == .brief { return "• \(entry.title) — \(progress(entry))" }
        var lines = ["• " + entry.title + otherNames(entry)]
        lines.append("  Статус: \(entry.status.rawValue) · \(progress(entry))")
        if let sources = sources(entry) { lines.append("  Источники: \(sources)") }
        if let available = Backlog.available(entry) { lines.append("  Не просмотрено в источнике: \(available)") }
        else if Backlog.caughtUp(entry) { lines.append("  Догнал: жду новые серии") }
        if let rating = entry.rating {
            let stars = String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
            lines.append("  Оценка: \(stars) (\(rating) из 5)")
        }
        if let tags = entry.tags, !tags.isEmpty { lines.append("  Метки: " + tags.joined(separator: ", ")) }
        let days = ReleasePlanner.days(entry)
        if !days.isEmpty { lines.append("  Выходит: \(days)") }
        if let premiere = entry.premiereDate, PremierePlanner.upcoming([entry], now: now, calendar: calendar).first != nil {
            lines.append("  Премьера: " + date(premiere, calendar: calendar))
        }
        if let pass = entry.passTitle { lines.append("  \(pass)") }
        if options.notes {
            if let point = entry.resumePoint {
                let time = point.time.isEmpty ? "" : " · \(point.time)"
                let text = point.text.isEmpty ? "" : " — \(oneLine(point.text))"
                lines.append("  Где остановился: серия \(point.episode)\(time)\(text)")
            }
            let note = oneLine(entry.note)
            if !note.isEmpty { lines.append("  Заметка: \(note)") }
        }
        if let watched = entry.watchedAt { lines.append("  Последний просмотр: " + date(watched, calendar: calendar)) }
        if options.links {
            if !entry.watchURL.isEmpty { lines.append("  Ссылка: \(entry.watchURL)") }
            for link in entry.links ?? [] { lines.append("  Ссылка (\(link.label)): \(link.url)") }
        }
        return lines.joined(separator: "\n")
    }

    static func progress(_ entry: Entry) -> String {
        var parts: [String] = []
        if let season = entry.season { parts.append("сезон \(season)") }
        if entry.episode == 0 { parts.append("не начато") }
        else if entry.status == .completed { parts.append("посмотрено до серии \(entry.episode)") }
        else { parts.append("остановился на серии \(entry.episode) (просмотрено: \(watched(entry.episode)))") }
        return parts.joined(separator: ", ")
    }

    static func watched(_ episode: Int) -> String { episode <= 1 ? "серия 1" : "1–\(episode)" }

    /// Other names of the same work, so a voice assistant can recognise it under any of them.
    static func otherNames(_ entry: Entry) -> String {
        var seen = Set([TitleMatcher.key(entry.title)])
        let names = ([entry.originalTitle] + (entry.aliases ?? [])).filter { name in
            let key = TitleMatcher.key(name)
            return !key.isEmpty && seen.insert(key).inserted
        }.prefix(3)
        return names.isEmpty ? "" : " (" + names.joined(separator: "; ") + ")"
    }

    static func sources(_ entry: Entry) -> String? {
        let enabled = (entry.subscriptions ?? []).filter(\.enabled)
        guard !enabled.isEmpty else { return nil }
        return enabled.map { source in
            Dubs.name(fromLabel: source.label) + (source.lastEpisode.map { " (доступна серия \($0))" } ?? "")
        }.joined(separator: ", ")
    }

    static func statistics(_ snapshot: Snapshot, now: Date, calendar: Calendar) -> String {
        let stats = WatchStats(snapshot: snapshot, now: now, calendar: calendar)
        let counts = WatchStatus.allCases.map { "\($0.rawValue) \(stats.byStatus[$0] ?? 0)" }.joined(separator: " · ")
        var lines = ["Итоги:", "Историй: \(snapshot.entries.count) (\(counts))", "Сумма номеров серий: \(stats.totalEpisodes)"]
        if let since = stats.trackingSince {
            lines.append("Отмечено в АниПолке: за 7 дней — \(stats.lastWeek), за 30 дней — \(stats.lastMonth), с начала года — \(stats.thisYear) (учёт с \(date(since, calendar: calendar)))")
        } else {
            lines.append("Отметки серий в АниПолке пока не ведутся: счёт начнётся с первого «+1».")
        }
        lines.append("Завершено в этом году: \(stats.completedThisYear)")
        if let average = stats.averageRating { lines.append("Средняя оценка: " + String(format: "%.1f", average).replacingOccurrences(of: ".", with: ",") + " из 5") }
        if !stats.topRated.isEmpty { lines.append("Оценка 5 звёзд: " + stats.topRated.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }

    static func date(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
}
