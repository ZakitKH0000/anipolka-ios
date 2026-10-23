import XCTest
@testable import ShelfCore

final class DiscoveryTests: XCTestCase {
    let address = "https://anivibe.pro/anime/44218-test"
    func page(episode: Int = 26) throws -> SourcePage {
        let object: [String:Any] = ["translations":[["id":910,"title":"Студия А","last_episode":episode,"season":1],["id":911,"title":"Студия Б","last_episode":100,"season":2]],"material_data":["anime_title":"История {с героем} \"цитата\""]]
        let json = String(data:try JSONSerialization.data(withJSONObject:object),encoding:.utf8)!
        return try AnivibePageParser.parse("""
        <meta property="og:image" content="https://example.org/poster.jpg?a=1&amp;b=2">
        <script>const kodikData = \(json);</script>
        """,url:address)
    }
    func testExactAutomaticCoverDoesNotGuessBetweenTitlesOrSeasons() {
        XCTAssertEqual(TitleIdentity.uniqueExactMatch(query:"Пожиратель звёзд⭐",candidates:[["Пожиратель звезд"],["Пожиратель звёзд 2"]]),0)
        XCTAssertNil(TitleIdentity.uniqueExactMatch(query:"Пожиратель звёзд",candidates:[["Пожиратель звёзд 2"],["Пожиратель звёзд 3"]]))
        XCTAssertNil(TitleIdentity.uniqueExactMatch(query:"История",candidates:[["История"],["История"]]))
        XCTAssertNil(TitleIdentity.uniqueExactMatch(query:"Исходнае название",candidates:[["Исходное название"]]))
        XCTAssertEqual(TitleIdentity.query("Любимое⭐ 2"),"Любимое 2")
    }
    func testPublicPageParserKeepsTranslationsSeparateAndDoesNotExecuteJavaScript() throws {
        let parsed = try page()
        XCTAssertEqual(parsed.options.count,2)
        XCTAssertEqual(parsed.options[0].episode,26); XCTAssertEqual(parsed.options[1].episode,100)
        XCTAssertEqual(parsed.options[0].id,"kodik-910-1")
        XCTAssertEqual(parsed.coverURL,"https://example.org/poster.jpg?a=1&b=2")
        let url = try XCTUnwrap(URLComponents(string:parsed.watchURL(for:parsed.options[0],episode:27)))
        XCTAssertEqual(url.queryItems?.first(where:{$0.name == "episode"})?.value,"27")
        XCTAssertEqual(url.queryItems?.first(where:{$0.name == "translation"})?.value,"Студия А")
        XCTAssertEqual(url.queryItems?.first(where:{$0.name == "player"})?.value,"kodik")
    }
    func testAniVibeContinuousNumberingAndTrackDeepLink() throws {
        let html = #"<meta property="og:title" content="История"><script>window.__vidozaData = window.__unpackVidozaGroups([{"vn":"Студия & А","tt":"voice","tl":"ru","eps":[{"e":26},{"e":246}]},{"vn":"Студия & А","tt":"sub","tl":"en","eps":[{"e":12}]}]);</script>"#
        let page = try AnivibePageParser.parse(html,url:address)
        XCTAssertEqual(page.options.count,2); XCTAssertEqual(page.options[0].episode,246)
        XCTAssertNotEqual(page.options[0].id,page.options[1].id)
        let link = try XCTUnwrap(URLComponents(string:page.watchURL(for:page.options[0],episode:247)))
        XCTAssertEqual(link.queryItems?.first(where:{$0.name == "translation"})?.value,"voice||ru||Студия & А")
        XCTAssertEqual(link.queryItems?.first(where:{$0.name == "player"})?.value,"anivibe")
        XCTAssertEqual(link.queryItems?.first(where:{$0.name == "episode"})?.value,"247")
    }
    func testRejectNonPageSourceAndMalformedHTML() {
        for value in ["http://anivibe.pro/anime/42", "https://example.org/anime/42", "https://anivibe.pro/api/test", "https://user@anivibe.pro/anime/42", "https://anivibe.pro:444/anime/42"] { XCTAssertNil(AnivibePageParser.canonicalURL(value)) }
        XCTAssertThrowsError(try AnivibePageParser.parse("<html>Нужен вход</html>",url:address))
        XCTAssertThrowsError(try AnivibePageParser.parse("const kodikData = {run: maliciousCode()};",url:address))
        XCTAssertEqual(AnivibePageParser.canonicalURL(address + "?episode=20#player-section")?.absoluteString,address)
    }
    func testDetectionBaselineAdvanceAndDedupDoNotChangeWatchedProgress() throws {
        let parsed = try page(); let source = ReleaseSubscription(pageURL:address,optionID:parsed.options[0].id,label:parsed.options[0].label,episode:26)
        var entry = Entry(title:"Моё название",episode:24); entry.subscriptions = [source]
        XCTAssertNil(try ReleaseTracker.observe(parsed,entry:&entry,subscriptionID:source.id))
        let found = try XCTUnwrap(ReleaseTracker.observe(try page(episode:29),entry:&entry,subscriptionID:source.id))
        XCTAssertEqual(found.previousEpisode,26); XCTAssertEqual(found.episode,29)
        XCTAssertEqual(entry.episode,24); XCTAssertEqual(entry.title,"Моё название")
        XCTAssertEqual(entry.releaseNotices?.count,1)
        XCTAssertNil(try ReleaseTracker.observe(try page(episode:29),entry:&entry,subscriptionID:source.id))
        XCTAssertEqual(entry.releaseNotices?.count,1)
    }
    func testNoFloodOnFirstObservationAndNoCounterRollback() throws {
        let parsed = try page()
        var source = ReleaseSubscription(pageURL:address,optionID:parsed.options[0].id,label:"Озвучка",episode:26); source.lastEpisode = nil
        var entry = Entry(title:"История"); entry.subscriptions = [source]
        XCTAssertNil(try ReleaseTracker.observe(parsed,entry:&entry,subscriptionID:source.id))
        let preserved = entry
        XCTAssertThrowsError(try ReleaseTracker.observe(try page(episode:20),entry:&entry,subscriptionID:source.id))
        XCTAssertEqual(entry,preserved)
    }
    func testMissingOrDisabledTranslationDoesNotCreateFalseNotice() throws {
        let parsed = try page(); var source = ReleaseSubscription(pageURL:address,optionID:"missing",label:"Озвучка",episode:1)
        var entry = Entry(title:"История"); entry.subscriptions = [source]
        XCTAssertThrowsError(try ReleaseTracker.observe(parsed,entry:&entry,subscriptionID:source.id))
        XCTAssertNil(entry.releaseNotices)
        source.enabled = false; entry.subscriptions = [source]
        XCTAssertNil(try ReleaseTracker.observe(parsed,entry:&entry,subscriptionID:source.id))
    }
    func testOldBackupMigrationAndNewTrackingRoundtrip() throws {
        var snapshot = Snapshot(); snapshot.entries = [Entry(title:"Старая коллекция",episode:150)]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:snapshot.encoded()) as? [String:Any])
        var prefs = try XCTUnwrap(json["preferences"] as? [String:Any])
        for key in ["automaticCovers","releaseNotifications","backgroundChecks"] { prefs.removeValue(forKey:key) }
        json["preferences"] = prefs
        let old = try Snapshot.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(old.entries[0].episode,150); XCTAssertTrue(old.preferences.automaticCovers); XCTAssertFalse(old.preferences.releaseNotifications)
        let p = try page(); let source = ReleaseSubscription(pageURL:address,optionID:p.options[0].id,label:p.options[0].label,episode:26)
        snapshot.entries[0].subscriptions = [source]
        _ = try ReleaseTracker.observe(try page(episode:27),entry:&snapshot.entries[0],subscriptionID:source.id)
        snapshot.entries[0].coverDiscovery = CoverDiscovery(query:"Привычное имя",message:"Найдена",needsChoice:false)
        XCTAssertEqual(try Snapshot.decode(snapshot.encoded()),snapshot)
    }
}
