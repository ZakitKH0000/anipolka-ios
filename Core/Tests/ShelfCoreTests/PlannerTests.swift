import XCTest
@testable import ShelfCore

final class PlannerTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(identifier:"Europe/Kiev")!; return c }
    func date(_ y: Int,_ m: Int,_ d: Int,_ h: Int = 12) -> Date { calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h))! }

    func testOldCollectionWithoutNewFieldsStillLoads() throws {
        let id = UUID()
        let json = #"{"format":"AniPolka","version":1,"entries":[{"id":"\#(id.uuidString)","title":"Моё название","originalTitle":"","episode":24,"status":"Смотрю","favorite":false,"note":"","watchURL":"","sourceURL":"","coverURL":"","updatedAt":0}],"preferences":{"theme":"Тёмное"}}"#
        let snapshot = try Snapshot.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.entries[0].episode,24); XCTAssertNil(snapshot.entries[0].rating)
        XCTAssertNil(snapshot.entries[0].releaseDays); XCTAssertNil(snapshot.entries[0].tags); XCTAssertNil(snapshot.history)
        XCTAssertFalse(snapshot.preferences.dailyDigest); XCTAssertEqual(snapshot.preferences.digestMinutes,19 * 60)
    }
    func testNewFieldsRoundtripAndValidation() throws {
        var s = Snapshot(); var e = Entry(title:"История",episode:3)
        e.rating = 5; e.releaseDays = [2,5]; e.tags = ["дунхуа"]; e.completedAt = date(2026,10,1)
        s.entries = [e]; s.preferences.dailyDigest = true; s.preferences.digestMinutes = 20 * 60 + 30
        s.recordWatch(entryID:e.id,episodes:2,at:date(2026,10,20))
        XCTAssertEqual(try Snapshot.decode(s.encoded()),s)
        for broken in [6,0] { var bad = s; bad.entries[0].rating = broken; XCTAssertThrowsError(try bad.encoded()) }
        var badDay = s; badDay.entries[0].releaseDays = [8]; XCTAssertThrowsError(try badDay.encoded())
        var badTag = s; badTag.entries[0].tags = [""]; XCTAssertThrowsError(try badTag.encoded())
        var badMark = s; badMark.history = [WatchMark(entryID:e.id,at:Date(),episodes:0)]; XCTAssertThrowsError(try badMark.encoded())
    }
    func testIncrementRecordsHistoryAndUndoRemovesIt() throws {
        let r = try ShelfRepository(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shelf.json"))
        var s = Snapshot(); let e = Entry(title:"История",episode:24); s.entries = [e]; try r.commit(s)
        let first = try XCTUnwrap(r.increment(e.id,now:date(2026,10,20)))
        _ = try XCTUnwrap(r.increment(e.id,now:date(2026,10,21)))
        XCTAssertEqual(r.snapshot.history?.count,2)
        try r.undo(first) // Ignored: a newer +1 exists, so history must stay consistent with progress.
        XCTAssertEqual(r.snapshot.entries[0].episode,26); XCTAssertEqual(r.snapshot.history?.count,2)
        let third = try XCTUnwrap(r.increment(e.id,now:date(2026,10,22)))
        try r.undo(third)
        XCTAssertEqual(r.snapshot.history?.map(\.at),[date(2026,10,20),date(2026,10,21)])
    }
    func testEditorSaveCountsProgressAndCompletionDate() {
        var s = Snapshot(); let e = Entry(title:"История",episode:10); s.entries = [e]
        var edited = e; edited.episode = 13; edited.status = .completed
        s.save(edited,now:date(2026,10,24))
        XCTAssertEqual(s.history,[WatchMark(entryID:e.id,at:date(2026,10,24),episodes:3)])
        XCTAssertEqual(s.entries[0].completedAt,date(2026,10,24))
        var lowered = s.entries[0]; lowered.episode = 5; lowered.status = .watching
        s.save(lowered,now:date(2026,10,25))
        XCTAssertEqual(s.history?.count,1); XCTAssertNil(s.entries[0].completedAt)
        var fresh = Entry(title:"Новая",episode:48); fresh.status = .completed
        s.save(fresh,now:date(2026,10,26))
        XCTAssertEqual(s.history?.count,1, "Adding an already watched title is not new viewing")
        XCTAssertEqual(s.entries[1].completedAt,date(2026,10,26))
    }
    func testHistoryIsBounded() {
        var s = Snapshot(); let id = UUID()
        s.history = (0..<WatchMark.limit).map { WatchMark(entryID:id,at:Date(timeIntervalSince1970:Double($0)),episodes:1) }
        s.recordWatch(entryID:id,episodes:1,at:Date(timeIntervalSince1970:1e9))
        XCTAssertEqual(s.history?.count,WatchMark.limit); XCTAssertEqual(s.history?.first?.at,Date(timeIntervalSince1970:1))
    }
    func testTagsParsingFilteringAndSearch() {
        XCTAssertEqual(Tags.parse(" дунхуа, С другом ,дунхуа;#пересмотреть,, "),["дунхуа","С другом","пересмотреть"])
        XCTAssertEqual(Tags.parse(String(repeating:"я",count:60)).first?.count,Tags.maxLength)
        XCTAssertEqual(Tags.parse((1...30).map(String.init).joined(separator:",")).count,Tags.limit)
        var s = Snapshot(); var a = Entry(title:"Альфа"); a.tags = ["Дунхуа"]; let b = Entry(title:"Бета")
        s.entries = [a,b]; s.preferences.sort = .manual
        XCTAssertEqual(s.visible(tag:"дунхуа").map(\.title),["Альфа"])
        XCTAssertEqual(s.visible(query:"дунх").map(\.title),["Альфа"])
        XCTAssertEqual(Tags.all(s.entries),["Дунхуа"])
    }
    func testBacklogUsesEnabledSourcesAndIgnoresImplausibleNumbering() {
        var e = Entry(title:"История",episode:24)
        XCTAssertNil(Backlog.available(e))
        var source = ReleaseSubscription(pageURL:"https://anivibe.pro/anime/44218",optionID:"a",label:"Озвучка",episode:27)
        e.subscriptions = [source]; XCTAssertEqual(Backlog.available(e),3)
        source.enabled = false; e.subscriptions = [source]; XCTAssertNil(Backlog.available(e))
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/1",optionID:"b",label:"Сквозная",episode:24 + 150)]
        XCTAssertNil(Backlog.available(e), "Different numbering must not look like 150 unwatched episodes")
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/1",optionID:"c",label:"Сезон",episode:10)]
        XCTAssertNil(Backlog.available(e))
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/1",optionID:"d",label:"Озвучка",episode:30)]
        e.status = .dropped; XCTAssertNil(Backlog.available(e))
        var s = Snapshot(); e.status = .watching; s.entries = [e,Entry(title:"Без источника")]
        XCTAssertEqual(s.visible(behindOnly:true).map(\.title),["История"])
    }
    func testScheduleDigestAndContinuingOrder() {
        var a = Entry(title:"Пожиратель звёзд"); a.releaseDays = [7]
        var b = Entry(title:"Пик боевых искусств"); b.releaseDays = [2,7]; b.status = .planned
        var c = Entry(title:"Брошенная"); c.releaseDays = [7]; c.status = .dropped
        XCTAssertEqual(ReleasePlanner.due([a,b,c],weekday:7).map(\.title),["Пожиратель звёзд","Пик боевых искусств"])
        XCTAssertEqual(ReleasePlanner.weekday(of:date(2026,10,24),calendar:calendar),7) // суббота
        XCTAssertEqual(ReleasePlanner.days(b),"Пн, Сб")
        XCTAssertEqual(ReleasePlanner.digestBody(["А"]),"«А»")
        XCTAssertEqual(ReleasePlanner.digestBody(["А","Б","В"]),"«А», «Б» и «В»")
        XCTAssertEqual(ReleasePlanner.digestBody(["1","2","3","4","5","6"]),"«1», «2», «3», «4» и ещё 2")
        a.watchedAt = date(2026,10,20); var d = Entry(title:"Свежая"); d.watchedAt = date(2026,10,23)
        XCTAssertEqual(ReleasePlanner.continuing([a,b,d],limit:5).map(\.title),["Свежая","Пожиратель звёзд"])
    }
    func testStatistics() {
        var s = Snapshot(); let now = date(2026,10,24)
        var a = Entry(title:"А",episode:24); a.rating = 5; a.status = .completed; a.completedAt = date(2026,3,1)
        var b = Entry(title:"Б",episode:10); b.rating = 4; b.completedAt = nil
        var c = Entry(title:"В",episode:6); c.status = .completed; c.completedAt = date(2025,12,31)
        s.entries = [a,b,c]
        s.history = [WatchMark(entryID:a.id,at:date(2026,10,23),episodes:2),WatchMark(entryID:b.id,at:date(2026,10,5),episodes:3),
                     WatchMark(entryID:b.id,at:date(2026,1,5),episodes:1),WatchMark(entryID:c.id,at:date(2025,12,30),episodes:4)]
        let stats = WatchStats(snapshot:s,now:now,calendar:calendar)
        XCTAssertEqual(stats.lastWeek,2); XCTAssertEqual(stats.lastMonth,5); XCTAssertEqual(stats.thisYear,6)
        XCTAssertEqual(stats.trackingSince,date(2025,12,30)); XCTAssertEqual(stats.totalEpisodes,40)
        XCTAssertEqual(stats.byStatus[.completed],2); XCTAssertEqual(stats.byStatus[.watching],1)
        XCTAssertEqual(stats.completedThisYear,1); XCTAssertEqual(stats.averageRating,4.5); XCTAssertEqual(stats.topRated,["А"])
    }
}
