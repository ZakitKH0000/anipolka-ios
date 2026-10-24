import XCTest
@testable import ShelfCore

final class ExtrasTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Europe/Kiev")!; return c }
    func date(_ y: Int,_ m: Int,_ d: Int,_ h: Int = 12) -> Date { calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h))! }

    func testEpisodeTimeNormalization() {
        XCTAssertEqual(EpisodeTime.normalized("14:30"),"14:30")
        XCTAssertEqual(EpisodeTime.normalized(" 4.05 "),"4:05")
        XCTAssertEqual(EpisodeTime.normalized("1:02:03"),"1:02:03")
        XCTAssertEqual(EpisodeTime.normalized(""),"")
        for bad in ["14:75","abc","14","1:2:3:4","-1:00","25:00:00"] { XCTAssertNil(EpisodeTime.normalized(bad),bad) }
    }
    func testNotesResumePointAndLimit() {
        var e = Entry(title:"История",episode:24)
        e.addNote(EpisodeNote(episode:25,time:"14:30",text:"ПВА ШОУ",createdAt:date(2026,10,20)))
        e.addNote(EpisodeNote(episode:24,time:"",text:"старая",createdAt:date(2026,10,1)))
        XCTAssertEqual(e.resumePoint?.text,"ПВА ШОУ", "The newest note is where the user stopped")
        for i in 0..<EpisodeNote.limit { e.addNote(EpisodeNote(episode:i,createdAt:date(2026,11,1).addingTimeInterval(Double(i)))) }
        XCTAssertEqual(e.notes?.count,EpisodeNote.limit); XCTAssertEqual(e.resumePoint?.episode,EpisodeNote.limit - 1)
    }
    func testLinksPromotionKeepsPreviousMainLink() {
        var e = Entry(title:"История"); e.watchURL = "https://anivibe.pro/anime/44218"
        let playlist = WatchLink(label:"VK · плейлист 2 сезона",url:"https://vkvideo.ru/playlist/-1_2")
        e.links = [playlist]
        e.promoteLink(playlist.id)
        XCTAssertEqual(e.watchURL,playlist.url)
        XCTAssertEqual(e.links?.map(\.url),["https://anivibe.pro/anime/44218"]); XCTAssertEqual(e.links?.first?.label,"Прежняя основная")
        e.promoteLink(UUID()); XCTAssertEqual(e.watchURL,playlist.url)
    }
    func testRewatchKeepsFirstPass() {
        var e = Entry(title:"История",episode:48); e.status = .completed
        e.startRewatch(now:date(2026,10,24))
        XCTAssertEqual(e.episode,0); XCTAssertEqual(e.status,.watching); XCTAssertEqual(e.firstRunEpisode,48); XCTAssertEqual(e.rewatch,1)
        XCTAssertEqual(e.passTitle,"Пересмотр №2 · в прошлый раз: 48")
        e.episode = 10; e.startRewatch(); XCTAssertEqual(e.firstRunEpisode,48); XCTAssertEqual(e.rewatch,2)
    }
    func testNewFieldsRoundtripAndValidation() throws {
        var s = Snapshot(); var e = Entry(title:"История")
        e.notes = [EpisodeNote(episode:3,time:"1:00",text:"т",createdAt:date(2026,10,1))]
        e.links = [WatchLink(label:"AniVibe",url:"https://anivibe.pro/anime/1")]
        e.rewatch = 1; e.firstRunEpisode = 12; e.premiereDate = date(2026,11,1)
        s.entries = [e]; s.preferences.shelves = true
        XCTAssertEqual(try Snapshot.decode(s.encoded()),s)
        var badLink = s; badLink.entries[0].links = [WatchLink(label:"x",url:"javascript:alert(1)")]; XCTAssertThrowsError(try badLink.encoded())
        var badNote = s; badNote.entries[0].notes = [EpisodeNote(episode:-1)]; XCTAssertThrowsError(try badNote.encoded())
    }
    func testPremieresAndShelves() {
        let now = date(2026,10,24)
        var soon = Entry(title:"Скоро"); soon.status = .planned; soon.premiereDate = date(2026,10,25,0)
        var today = Entry(title:"Сегодня"); today.status = .planned; today.premiereDate = date(2026,10,24,8)
        var past = Entry(title:"Прошла"); past.status = .planned; past.premiereDate = date(2026,10,1)
        var dropped = Entry(title:"Брошена"); dropped.status = .dropped; dropped.premiereDate = date(2026,12,1)
        XCTAssertEqual(PremierePlanner.upcoming([soon,today,past,dropped],now:now,calendar:calendar).map(\.title),["Сегодня","Скоро"])
        XCTAssertEqual(PremierePlanner.label(today.premiereDate!,now:now,calendar:calendar),"Премьера сегодня")
        XCTAssertEqual(PremierePlanner.label(soon.premiereDate!,now:now,calendar:calendar),"Премьера завтра")
        XCTAssertTrue(PremierePlanner.label(date(2026,11,12),now:now,calendar:calendar).hasPrefix("Премьера 12"))

        var behind = Entry(title:"Новые",episode:1)
        behind.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/2",optionID:"b",label:"x",episode:3)]
        let watching = Entry(title:"Смотрю")
        var done = Entry(title:"Готово"); done.status = .completed
        let sections = ShelfSections.make([watching,done,behind,soon,past,dropped],now:now,calendar:calendar)
        XCTAssertEqual(sections.map(\.title),["Есть новые серии","Смотрю","Скоро премьера","На потом","Завершено","Заброшено"])
        XCTAssertEqual(sections[0].entries.map(\.title),["Новые"]); XCTAssertEqual(sections[1].entries.map(\.title),["Смотрю"], "Each title appears once")
        XCTAssertEqual(sections[3].entries.map(\.title),["Прошла"])
    }
    func testFavoriteDubsOrderFilterAndToggle() {
        XCTAssertEqual(Dubs.name(fromLabel:"ПВА ШОУ · сезон 2 · Kodik"),"ПВА ШОУ")
        XCTAssertEqual(Dubs.name(fromLabel:"AniStar · озвучка ru · AniVibe"),"AniStar")
        let options = [SourceOption(id:"a",label:"Animy · сезон 1 · Kodik",episode:60),SourceOption(id:"b",label:"ПВА ШОУ · сезон 1 · Kodik",episode:60),
                       SourceOption(id:"c",label:"ПВА ШОУ · озвучка ru · AniVibe",episode:60,player:"anivibe")]
        XCTAssertEqual(Dubs.sorted(options,favorites:["пва шоу"]).map(\.id),["b","c","a"])
        var favorites = Dubs.toggled("ПВА ШОУ",in:[]); XCTAssertEqual(favorites,["ПВА ШОУ"])
        favorites = Dubs.toggled("пва шоу",in:favorites); XCTAssertEqual(favorites,[])
        var e = Entry(title:"История с озвучкой")
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/61929",optionID:"b",label:"ПВА ШОУ · сезон 1 · Kodik",episode:60)]
        var s = Snapshot(); s.entries = [e,Entry(title:"Другая")]
        XCTAssertEqual(s.visible(dub:"ПВА ШОУ").map(\.title),["История с озвучкой"])
        XCTAssertEqual(Dubs.inUse(s.entries,favorites:["ПВА ШОУ","RuChime"]),["ПВА ШОУ"])
    }
    func testWeekPlanStartsTodayWithReleasesAndPremieres() {
        let now = date(2026,10,24) // суббота
        var a = Entry(title:"Субботняя"); a.releaseDays = [7]
        var b = Entry(title:"Понедельник"); b.releaseDays = [2]
        var p = Entry(title:"Премьера"); p.status = .planned; p.premiereDate = date(2026,10,27,9)
        let days = WeekPlan.days([a,b,p],now:now,calendar:calendar)
        XCTAssertEqual(days.count,7); XCTAssertEqual(days[0].date,calendar.startOfDay(for:now))
        XCTAssertEqual(days[0].releases,["Субботняя"]); XCTAssertEqual(days[2].releases,["Понедельник"])
        XCTAssertEqual(days[3].premieres,["Премьера"]); XCTAssertTrue(days[1].releases.isEmpty && days[1].premieres.isEmpty)
    }
    func testRelationsWorkBothWaysAndUnlink() {
        var s1 = Entry(title:"Пожиратель звёзд"); let s4 = Entry(title:"Пожиратель звёзд 4"), movie = Entry(title:"Фильм")
        s1.relatedIDs = [s4.id]
        var other = movie; other.relatedIDs = [s1.id]
        var s = Snapshot(); s.entries = [s1,s4,other]
        XCTAssertEqual(Relations.related(of:s1,in:s.entries).map(\.title),["Пожиратель звёзд 4","Фильм"])
        XCTAssertEqual(Relations.related(of:s4,in:s.entries).map(\.title),["Пожиратель звёзд"])
        Relations.unlink(s1.id,movie.id,in:&s)
        XCTAssertEqual(Relations.related(of:s.entries[0],in:s.entries).map(\.title),["Пожиратель звёзд 4"])
        XCTAssertNil(s.entries[2].relatedIDs)
    }
    func testIncrementBySeveralEpisodesRecordsOneMarkAndUndoes() throws {
        let r = try ShelfRepository(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shelf.json"))
        var s = Snapshot(); let e = Entry(title:"История",episode:24); s.entries = [e]; try r.commit(s)
        let token = try XCTUnwrap(r.increment(e.id,by:3,now:date(2026,10,24)))
        XCTAssertEqual(r.snapshot.entries[0].episode,27); XCTAssertEqual(r.snapshot.history?.map(\.episodes),[3])
        try r.undo(token); XCTAssertEqual(r.snapshot.entries[0].episode,24); XCTAssertEqual(r.snapshot.history?.count,0)
        XCTAssertNil(try r.increment(e.id,by:0))
    }
    func testYearSummary() {
        var s = Snapshot()
        var a = Entry(title:"А"); a.rating = 5; a.status = .completed; a.completedAt = date(2026,5,1)
        let b = Entry(title:"Б")
        s.entries = [a,b]
        s.history = [WatchMark(entryID:a.id,at:date(2026,3,1,10),episodes:2),WatchMark(entryID:a.id,at:date(2026,3,1,20),episodes:1),
                     WatchMark(entryID:b.id,at:date(2026,4,1),episodes:5),WatchMark(entryID:b.id,at:date(2025,4,1),episodes:50)]
        let summary = YearSummary(snapshot:s,year:2026,calendar:calendar)
        XCTAssertEqual(summary.episodes,8); XCTAssertEqual(summary.activeDays,2); XCTAssertEqual(summary.mostWatched,"Б")
        XCTAssertEqual(summary.completed,["А"]); XCTAssertEqual(summary.topRated,["А"])
    }
}
