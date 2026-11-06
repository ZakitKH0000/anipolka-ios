import XCTest
@testable import ShelfCore

final class ReportTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Europe/Kiev")!; return c }
    func date(_ y: Int,_ m: Int,_ d: Int,_ h: Int = 12) -> Date { calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h))! }
    var now: Date { date(2026,11,6) }

    /// Four titles in different states; the manual order keeps the output predictable.
    func snapshot() -> Snapshot {
        var s = Snapshot(); s.preferences.sort = .manual
        var star = Entry(title:"Пожиратель звёзд",episode:24)
        star.originalTitle = "Tunshi Xingkong"; star.aliases = ["Swallowed Star","Tun Shi Xing Kong"]
        star.rating = 4; star.tags = ["дунхуа"]; star.releaseDays = [2,7]; star.watchedAt = date(2026,11,3)
        star.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/44218",optionID:"a",label:"ПВА ШОУ · сезон 1 · Kodik",episode:27)]
        star.addNote(EpisodeNote(episode:25,time:"14:30",text:"смотрю в озвучке ПВА ШОУ",createdAt:date(2026,11,2)))
        star.note = "Первая\nстрока"
        var peak = Entry(title:"Пик боевых искусств"); peak.status = .planned
        var shepherd = Entry(title:"Сказание",episode:104); shepherd.status = .completed; shepherd.season = 2; shepherd.rating = 5
        var dropped = Entry(title:"Брошенная",episode:1); dropped.status = .dropped
        s.entries = [star,peak,shepherd,dropped]
        s.history = [WatchMark(entryID:star.id,at:date(2026,11,3),episodes:2),WatchMark(entryID:star.id,at:date(2026,10,10),episodes:3)]
        return s
    }
    func options(_ style: ReportOptions.Style) -> ReportOptions { var o = ReportOptions(); o.style = style; o.statistics = false; return o }

    func testBriefTextListsEveryTitleWithItsProgress() {
        let text = ShelfReport.text(snapshot(),options:options(.brief),now:now,calendar:calendar)
        XCTAssertEqual(text,"""
        Смотрю (1):
        • Пожиратель звёзд — остановился на серии 24 (просмотрено: 1–24)

        На потом (1):
        • Пик боевых искусств — не начато

        Завершено (1):
        • Сказание — сезон 2, посмотрено до серии 104

        Заброшено (1):
        • Брошенная — остановился на серии 1 (просмотрено: серия 1)
        """)
    }
    func testStatusSelectionLimitsTheList() {
        var o = options(.brief); o.statuses = [.watching,.dropped]
        let text = ShelfReport.text(snapshot(),options:o,now:now,calendar:calendar)
        XCTAssertTrue(text.contains("Смотрю (1):")); XCTAssertTrue(text.contains("Заброшено (1):"))
        XCTAssertFalse(text.contains("На потом")); XCTAssertFalse(text.contains("Завершено"))
        o.statuses = []
        XCTAssertEqual(ShelfReport.text(Snapshot(),options:o,now:now,calendar:calendar),"Список пуст или ничего не выбрано.")
    }
    func testDetailedTextCarriesSourcesNotesNamesAndDates() {
        let text = ShelfReport.text(snapshot(),options:options(.detailed),now:now,calendar:calendar)
        for line in [
            "• Пожиратель звёзд (Tunshi Xingkong; Swallowed Star)",
            "  Статус: Смотрю · остановился на серии 24 (просмотрено: 1–24)",
            "  Источники: ПВА ШОУ (доступна серия 27)",
            "  Не просмотрено в источнике: 3",
            "  Оценка: ★★★★☆ (4 из 5)",
            "  Метки: дунхуа",
            "  Выходит: Пн, Сб",
            "  Где остановился: серия 25 · 14:30 — смотрю в озвучке ПВА ШОУ",
            "  Заметка: Первая строка",
            "  Последний просмотр: 3 ноября 2026",
            "  Статус: Завершено · сезон 2, посмотрено до серии 104",
            "  Оценка: ★★★★★ (5 из 5)"
        ] { XCTAssertTrue(text.contains(line),line) }
        XCTAssertFalse(text.contains("Tun Shi Xing Kong"), "A spelling variant of the original title is not listed twice")
        XCTAssertFalse(text.contains("Ссылка"), "Links are off by default")
    }
    func testNotesAndLinksFollowTheirSwitches() {
        var s = snapshot()
        s.entries[0].watchURL = "https://anivibe.pro/anime/44218?episode=24"
        s.entries[0].links = [WatchLink(label:"VK · плейлист",url:"https://vkvideo.ru/playlist/-1_2")]
        var o = options(.detailed); o.notes = false; o.links = true
        let text = ShelfReport.text(s,options:o,now:now,calendar:calendar)
        XCTAssertFalse(text.contains("Где остановился")); XCTAssertFalse(text.contains("Заметка"))
        XCTAssertTrue(text.contains("  Ссылка: https://anivibe.pro/anime/44218?episode=24"))
        XCTAssertTrue(text.contains("  Ссылка (VK · плейлист): https://vkvideo.ru/playlist/-1_2"))
        // The brief style never includes notes or links.
        o.style = .brief
        let brief = ShelfReport.text(s,options:o,now:now,calendar:calendar)
        XCTAssertFalse(brief.contains("Ссылка")); XCTAssertFalse(brief.contains("Заметка"))
    }
    func testCaughtUpAndRewatchAreMentioned() {
        var s = Snapshot(); s.preferences.sort = .manual
        var e = Entry(title:"Догнал",episode:26)
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/1",optionID:"a",label:"Animy · Kodik",episode:26)]
        e.startRewatch(now:date(2026,11,1)); e.episode = 3; e.firstRunEpisode = 26
        s.entries = [e]
        let text = ShelfReport.text(s,options:options(.detailed),now:now,calendar:calendar)
        XCTAssertTrue(text.contains("  Пересмотр №2 · в прошлый раз: 26"))
        XCTAssertFalse(text.contains("Догнал: жду"), "Three of 26 episodes after a rewatch is not caught up")
        var caught = Entry(title:"Свежая",episode:26)
        caught.subscriptions = e.subscriptions
        s.entries = [caught]
        XCTAssertTrue(ShelfReport.text(s,options:options(.detailed),now:now,calendar:calendar).contains("  Догнал: жду новые серии"))
    }
    func testStatisticsBlock() {
        var o = ReportOptions(); o.style = .brief
        let text = ShelfReport.text(snapshot(),options:o,now:now,calendar:calendar)
        for line in [
            "Итоги:",
            "Историй: 4 (Смотрю 1 · На потом 1 · Завершено 1 · Заброшено 1)",
            "Сумма номеров серий: 129",
            "Отмечено в АниПолке: за 7 дней — 2, за 30 дней — 5, с начала года — 5 (учёт с 10 октября 2026)",
            "Завершено в этом году: 0",
            "Средняя оценка: 4,5 из 5",
            "Оценка 5 звёзд: Сказание"
        ] { XCTAssertTrue(text.contains(line),line) }
        XCTAssertTrue(ShelfReport.text(Snapshot(),options:o,now:now,calendar:calendar).contains("счёт начнётся с первого «+1»"))
    }
    func testAITextExplainsTheFormatAndLeavesRoomForAQuestion() {
        var o = ReportOptions(); o.style = .forAI
        let text = ShelfReport.text(snapshot(),options:o,now:now,calendar:calendar)
        XCTAssertTrue(text.hasPrefix("Это мой личный список аниме и дунхуа из приложения АниПолка на 6 ноября 2026."))
        XCTAssertTrue(text.contains("прямо говори, если чего-то не знаешь"))
        XCTAssertTrue(text.contains("• Пожиратель звёзд (Tunshi Xingkong; Swallowed Star)"))
        XCTAssertTrue(text.hasSuffix("Мой вопрос: "))
    }
    func testLongNotesAreShortened() {
        var s = Snapshot(); var e = Entry(title:"Длинная"); e.note = String(repeating:"а",count:500); s.entries = [e]
        let text = ShelfReport.text(s,options:options(.detailed),now:now,calendar:calendar)
        let line = text.components(separatedBy:"\n").first { $0.hasPrefix("  Заметка: ") } ?? ""
        XCTAssertEqual(line.count,"  Заметка: ".count + 301); XCTAssertTrue(line.hasSuffix("…"))
    }
    func testPremiereOnlyWhileItIsUpcoming() {
        var s = Snapshot(); var soon = Entry(title:"Скоро"); soon.status = .planned; soon.premiereDate = date(2026,11,12)
        var past = Entry(title:"Прошла"); past.status = .planned; past.premiereDate = date(2026,10,1)
        s.entries = [soon,past]; s.preferences.sort = .manual
        let text = ShelfReport.text(s,options:options(.detailed),now:now,calendar:calendar)
        XCTAssertTrue(text.contains("  Премьера: 12 ноября 2026"))
        XCTAssertEqual(text.components(separatedBy:"Премьера").count,2)
    }
}
