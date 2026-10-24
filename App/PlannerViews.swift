import SwiftUI

func episodesWord(_ n: Int) -> String {
    let tens = n % 100, ones = n % 10
    if (11...14).contains(tens) { return "серий" }
    if ones == 1 { return "серия" }
    return (2...4).contains(ones) ? "серии" : "серий"
}

struct RatingStars: View {
    @Binding var rating: Int?
    var body: some View {
        HStack(spacing:0) {
            ForEach(1...5,id:\.self) { star in
                Button { rating = rating == star ? nil : star } label: {
                    Image(systemName:star <= (rating ?? 0) ? "star.fill" : "star").font(.title3).foregroundStyle(.yellow).frame(minWidth:36,minHeight:44)
                }.buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Моя оценка")
        .accessibilityValue(rating.map { "\($0) из 5" } ?? "Без оценки")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min((rating ?? 0) + 1,5)
            case .decrement: let value = (rating ?? 0) - 1; rating = value > 0 ? value : nil
            @unknown default: break
            }
        }
        .accessibilityIdentifier("rating")
    }
}

struct WeekdayPicker: View {
    @Binding var days: [Int]
    private let names = ["воскресенье","понедельник","вторник","среда","четверг","пятница","суббота"]
    var body: some View {
        HStack(spacing:5) {
            ForEach(ReleasePlanner.displayOrder,id:\.self) { day in
                let selected = days.contains(day)
                Button { if selected { days.removeAll { $0 == day } } else { days = (days + [day]).sorted() } } label: {
                    Text(ReleasePlanner.shortName(day)).font(.subheadline.weight(selected ? .bold : .regular)).frame(maxWidth:.infinity,minHeight:40)
                        .background(selected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.08),in:Capsule())
                        .foregroundStyle(selected ? Color.blue : Color.primary)
                }.buttonStyle(.borderless).accessibilityLabel(names[day - 1]).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }.accessibilityIdentifier("release-days")
    }
}

struct TagChips: View {
    let tags: [String]
    var body: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                ForEach(tags,id:\.self) { Text("#\($0)").font(.caption).padding(.horizontal,10).padding(.vertical,6).background(Color.secondary.opacity(0.12),in:Capsule()) }
            }
        }.accessibilityLabel("Метки: \(tags.joined(separator:", "))")
    }
}

/// Small status line under a title: available episodes, today's release and the rating.
struct EntryBadges: View {
    let entry: Entry
    var body: some View {
        let available = Backlog.available(entry)
        let today = (entry.releaseDays ?? []).contains(ReleasePlanner.weekday(of:Date())) && (entry.status == .watching || entry.status == .planned)
        let caughtUp = Backlog.caughtUp(entry)
        let upcomingPremiere = PremierePlanner.upcoming([entry]).first?.premiereDate
        if available != nil || today || caughtUp || upcomingPremiere != nil || entry.rating != nil {
            HStack(spacing:8) {
                if let available { Text("+\(available) \(episodesWord(available))").font(.caption.bold()).foregroundStyle(.blue) }
                if caughtUp { Label("Догнал",systemImage:"hourglass").font(.caption).foregroundStyle(.secondary) }
                if today { Label("Сегодня выход",systemImage:"calendar").font(.caption).foregroundStyle(.orange) }
                if let premiere = upcomingPremiere { Label(PremierePlanner.label(premiere),systemImage:"sparkles").font(.caption).foregroundStyle(.orange) }
                if let rating = entry.rating { Text(String(repeating:"★",count:rating)).font(.caption).foregroundStyle(.yellow).accessibilityLabel("Оценка \(rating) из 5") }
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject var store: ShelfStore
    var body: some View {
        let stats = WatchStats(snapshot:store.snapshot)
        List {
            Section {
                row("За 7 дней","\(stats.lastWeek) \(episodesWord(stats.lastWeek))")
                row("За 30 дней","\(stats.lastMonth) \(episodesWord(stats.lastMonth))")
                row("В этом году","\(stats.thisYear) \(episodesWord(stats.thisYear))")
            } header: { Text("Отмечено серий") } footer: {
                Text(stats.trackingSince.map { "Учитываются отметки в АниПолке начиная с \($0.formatted(date:.long,time:.omitted)). Прогресс, внесённый до обновления, в эти числа не входит." } ?? "Счёт начнётся с первого «+1» или изменения номера серии в карточке.")
            }
            Section("Коллекция") {
                row("Сумма номеров ваших серий","\(stats.totalEpisodes)")
                ForEach(WatchStatus.allCases) { status in row(status.rawValue,"\(stats.byStatus[status] ?? 0)") }
                row("Завершено в этом году","\(stats.completedThisYear)")
            }
            YearCardSection()
            Section("Оценки") {
                row("Средняя оценка",stats.averageRating.map { "\($0.formatted(.number.precision(.fractionLength(1)))) ★" } ?? "пока нет")
                ForEach(stats.topRated,id:\.self) { Text("★★★★★  \($0)") }
            }
        }.navigationTitle("Итоги").accessibilityIdentifier("stats")
    }
    private func row(_ title: String,_ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }
}

struct DigestSettingsSection: View {
    @EnvironmentObject var store: ShelfStore
    @State private var message: String?
    @State private var asking = false
    private var prefs: Preferences { store.snapshot.preferences }
    var body: some View {
        Section {
            Toggle("Сводка в дни выхода",isOn:Binding(get:{prefs.dailyDigest},set:{ value in
                if !value { _ = store.change { $0.preferences.dailyDigest = false }; return }
                asking = true
                Task {
                    let allowed = await NotificationBridge.shared.enable()
                    _ = store.change { $0.preferences.dailyDigest = allowed }
                    message = allowed ? nil : "Уведомления не разрешены. Их можно включить в Настройках iPhone → АниПолка → Уведомления."
                    asking = false
                }
            })).disabled(asking).accessibilityIdentifier("daily-digest")
            if prefs.dailyDigest {
                DatePicker("Время сводки",selection:Binding(get:{
                    Calendar.current.date(bySettingHour:prefs.digestMinutes / 60,minute:prefs.digestMinutes % 60,second:0,of:Date()) ?? Date()
                },set:{ date in
                    let parts = Calendar.current.dateComponents([.hour,.minute],from:date)
                    _ = store.change { $0.preferences.digestMinutes = (parts.hour ?? 19) * 60 + (parts.minute ?? 0) }
                }),displayedComponents:.hourAndMinute)
            }
            Text(plan).font(.footnote).foregroundStyle(.secondary)
            if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
        } header: { Text("Дни выхода") } footer: { Text("Одно уведомление в выбранное время в дни, отмеченные в карточках историй. Напоминание ставит сам iPhone: интернет и сервер не нужны.") }
    }
    private var plan: String {
        let days = ReleasePlanner.displayOrder.compactMap { day -> String? in
            let count = ReleasePlanner.due(store.snapshot.entries,weekday:day).count
            return count > 0 ? "\(ReleasePlanner.shortName(day)) — \(count)" : nil
        }
        return days.isEmpty ? "Дни выхода ещё не указаны. Откройте историю → «Изменить» → «Дни выхода и метки»." : "По дням: " + days.joined(separator:", ")
    }
}

struct OpenedEntry: Identifiable { let id: UUID }
