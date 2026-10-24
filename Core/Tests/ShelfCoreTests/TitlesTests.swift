import XCTest
@testable import ShelfCore

final class TitlesTests: XCTestCase {
    func star() -> Entry {
        var e = Entry(title:"Пожиратель звёзд",episode:24); e.originalTitle = "Tunshi Xingkong"
        e.aliases = ["Swallowed Star","吞噬星空"]; return e
    }
    func testAliasesMergeSkipsDuplicatesAndOwnTitle() {
        XCTAssertEqual(Aliases.merge(["Swallowed Star"],adding:["swallowed  star!","Tun Shi Xing Kong","Пожиратель звёзд",""," 吞噬星空 "],except:["Пожиратель звёзд","Tunshi Xingkong"]),
                       ["Swallowed Star","吞噬星空"], "Spacing variants of the original title are the same name")
        XCTAssertEqual(Aliases.parse("Battle Through the Heavens, Season 5\n\nDoupo Cangqiong"),["Battle Through the Heavens, Season 5","Doupo Cangqiong"])
        XCTAssertEqual(Aliases.merge(nil,adding:(1...40).map { "Название \($0)" },except:[]).count,Aliases.limit)
        var e = star(); e.learnNames(["Пожиратель звёзд","Tunshi Xingkong","Звёздное поглощение"])
        XCTAssertEqual(e.title,"Пожиратель звёзд"); XCTAssertEqual(e.aliases,["Swallowed Star","吞噬星空","Звёздное поглощение"])
    }
    func testCollectionSearchAndImportDuplicatesUseAllNames() {
        var s = Snapshot(); s.entries = [star(),Entry(title:"Пик боевых искусств")]
        XCTAssertEqual(s.visible(query:"swallowed").map(\.title),["Пожиратель звёзд"])
        XCTAssertEqual(TitleMatcher.existing("Swallowed Star ★",in:s.entries)?.title,"Пожиратель звёзд")
        XCTAssertEqual(TitleMatcher.existing("TUN SHI XING KONG",in:s.entries)?.title,"Пожиратель звёзд")
        XCTAssertNil(TitleMatcher.existing("Swallowed Star 2",in:s.entries), "Another season is not a duplicate")
        XCTAssertNil(TitleMatcher.existing("Пи",in:s.entries))
    }
    func testSourcePageNamesMatchOrWarn() {
        XCTAssertTrue(TitleMatcher.matches(["Пожиратель звёзд 4","Tunshi Xingkong 4th Season"],star()), "Season page extends the base name")
        XCTAssertTrue(TitleMatcher.matches(["Swallowed Star"],star()))
        XCTAssertFalse(TitleMatcher.matches(["Сказание о пастухе богов","Mu shen ji"],star()))
        var doupo = Entry(title:"Моё название"); doupo.originalTitle = "Doupo Cangqiong: Nian Fan"
        XCTAssertTrue(TitleMatcher.matches(["Расколотая битвой синева небес 5","Dou po cang qiong"],doupo))
    }
    func testPageNamesAreReadFromMaterialData() throws {
        let html = #"<script>const kodikData = {"material_data":{"anime_title":"Сказание о пастухе богов","title_en":"Mu shen ji","other_titles":["Mu Shen Ji","ToHG"]},"translations":[{"id":1,"title":"ПВА ШОУ","last_episode":104}]};</script>"#
        let page = try AnivibePageParser.parse(html,url:"https://anivibe.pro/anime/59953-mushen-ji")
        XCTAssertEqual(page.names,["Сказание о пастухе богов","Mu shen ji","ToHG"])
    }
    func testSitemapParsingAndCandidateRanking() {
        let index = "<sitemapindex><sitemap><loc>https://anivibe.pro/sitemap-news-1.xml</loc></sitemap><sitemap><loc>https://evil.example/s.xml</loc></sitemap><sitemap><loc>https://anivibe.pro/page</loc></sitemap></sitemapindex>"
        XCTAssertEqual(AnivibeCatalog.sitemapFiles(in:index).map(\.absoluteString),["https://anivibe.pro/sitemap-news-1.xml"])
        let urls = ["https://anivibe.pro/anime/56524-tunshi-xingkong-4th-season","https://anivibe.pro/anime/44218-tunshi-xingkong",
                    "https://anivibe.pro/anime/44218-tunshi-xingkong","https://anivibe.pro/anime/59953-mushen-ji",
                    "https://anivibe.pro/news/1-tunshi-xingkong","https://anivibe.pro/anime/123"]
        let xml = urls.map { "<url><loc>\($0)</loc></url>" }.joined()
        let pages = AnivibeCatalog.pages(in:AnivibeCatalog.locations(in:xml))
        XCTAssertEqual(pages.count,4); XCTAssertEqual(pages[1].slugName,"tunshi xingkong")
        XCTAssertEqual(AnivibeCatalog.candidates(for:star(),in:pages).map(\.id),[44218,56524])
        XCTAssertTrue(AnivibeCatalog.candidates(for:Entry(title:"Пик боевых искусств"),in:pages).isEmpty)
    }
    func testWeeklyHistoryCaughtUpExportAndSuggestion() {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"Europe/Kiev")!; calendar.firstWeekday = 2
        let now = calendar.date(from:DateComponents(year:2026,month:10,day:24,hour:12))!
        let id = UUID(), other = UUID()
        var s = Snapshot()
        s.history = [WatchMark(entryID:id,at:now.addingTimeInterval(-3600),episodes:2),WatchMark(entryID:id,at:now.addingTimeInterval(-8 * 86400),episodes:1),
                     WatchMark(entryID:other,at:now,episodes:5),WatchMark(entryID:id,at:now.addingTimeInterval(-200 * 86400),episodes:9)]
        let marks = WatchHistory.marks(for:id,in:s)
        XCTAssertEqual(marks.map(\.episodes),[2,1,9])
        let weeks = WatchHistory.weekly(marks,weeks:3,now:now,calendar:calendar)
        XCTAssertEqual(weeks.map(\.episodes),[0,1,2]); XCTAssertEqual(weeks.last?.start,calendar.date(from:DateComponents(year:2026,month:10,day:19)))

        var e = Entry(title:"История",episode:27)
        e.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/1",optionID:"a",label:"Озвучка",episode:27)]
        XCTAssertTrue(Backlog.caughtUp(e)); e.episode = 26; XCTAssertFalse(Backlog.caughtUp(e))
        e.episode = 27; e.status = .completed; XCTAssertFalse(Backlog.caughtUp(e))

        let exported = ShelfExport.text([Entry(title:"Пожиратель звёзд",episode:24),Entry(title:"86",episode:0)])
        XCTAssertEqual(exported,"Пожиратель звёзд 24\n86 0")
        XCTAssertEqual(TextListParser.parse(exported).map(\.title),["Пожиратель звёзд","86"], "Export can be imported back")

        var planned = Entry(title:"На потом"); planned.status = .planned
        var behind = Entry(title:"Есть новые",episode:1); behind.subscriptions = [ReleaseSubscription(pageURL:"https://anivibe.pro/anime/2",optionID:"b",label:"x",episode:3)]
        let pool = [planned,behind,Entry(title:"Обычная"),{ var d = Entry(title:"Брошена"); d.status = .dropped; return d }()]
        XCTAssertEqual(Set(WatchSuggestion.pool(pool).map(\.title)),["На потом","Есть новые"])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 { XCTAssertNotEqual(WatchSuggestion.pick(pool,excluding:planned.id,using:&generator)?.id,planned.id) }
        XCTAssertEqual(WatchSuggestion.pick([planned],excluding:planned.id,using:&generator)?.id,planned.id, "A single option is still offered")
        XCTAssertNil(WatchSuggestion.pick([Entry(title:"Обычная")],using:&generator))
    }
}
