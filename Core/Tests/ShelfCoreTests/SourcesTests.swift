import XCTest
@testable import ShelfCore

final class SourcesTests: XCTestCase {
    func testAniListAndAniLibriaMergeIntoBroadcastData() throws {
        let aniList = #"{"data":{"Page":{"media":[{"idMal":63240,"nextAiringEpisode":{"episode":26,"airingAt":1795834800}},{"idMal":62789,"nextAiringEpisode":null}]}}}"#
        let next = try AniList.parse(Data(aniList.utf8))
        XCTAssertEqual(next[63240]?.episode, 26); XCTAssertNil(next[62789])

        let libria = #"[{"release":{"alias":"steel-ball-run","shikimori":{"id":58000},"publish_day":{"value":7}},"published_release_episode":{"ordinal":9},"next_release_episode_number":10},{"release":{"alias":"x","shikimori":null}}]"#
        let schedule = try AniLibria.parseSchedule(Data(libria.utf8))
        XCTAssertEqual(schedule.count, 1)
        XCTAssertEqual(schedule[58000]?.weekday, 1) // Sunday
        XCTAssertEqual(schedule[58000]?.publishedEpisode, 9)

        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let info = AiringInfo(checkedAt: now, status: Airing.ongoing, episodes: 52, episodesAired: 24)
        let merged = Airing.merge(info, aniList: next[63240], libria: schedule[58000], now: now)
        XCTAssertEqual(merged.nextEpisode, 26); XCTAssertEqual(merged.nextEpisodeAt, Date(timeIntervalSince1970: 1795834800))
        var e = Entry(title: "Путешествие к бессмертию 5", episode: 7); e.sourceID = 63240; e.airing = merged
        XCTAssertEqual(Airing.nextEpisode(e, now: now), 26)
        XCTAssertEqual(AniLibria.ahead(e), 2)
        // Survives a backup round trip.
        var s = Snapshot(); s.entries = [e]
        XCTAssertEqual(try Snapshot.decode(try s.encoded()).entries[0].airing?.libria?.alias, "steel-ball-run")
    }

    func testListImportFromShikimoriAndMyAnimeList() throws {
        let shikimori = #"[{"status":"watching","episodes":12,"anime":{"id":50444,"name":"Yong Sheng","russian":"Бессмертие","image":{"original":"/system/animes/original/50444.jpg"}}},{"status":"on_hold","episodes":0,"anime":{"id":1,"name":"Cowboy Bebop","russian":"Ковбой Бибоп","image":{"original":"/assets/globals/missing_original.jpg"}}}]"#
        let items = try ListImport.parseShikimori(Data(shikimori.utf8))
        XCTAssertEqual(items.map(\.status), [.watching, .planned])
        XCTAssertEqual(items[0].posterURL, "https://shikimori.io/system/animes/original/50444.jpg")
        let mal = #"[{"status":2,"num_watched_episodes":26,"anime_id":1,"anime_title":"Cowboy Bebop","anime_image_path":"https://cdn.myanimelist.net/1.jpg"}]"#
        XCTAssertEqual(try ListImport.parseMAL(Data(mal.utf8)).first?.status, .completed)

        var s = Snapshot(); var owned = Entry(title: "Бессмертие"); owned.sourceID = 50444; s.entries = [owned]
        let marked = ListImport.mark(items, in: s)
        XCTAssertFalse(marked[0].included); XCTAssertEqual(marked[0].existing, "Бессмертие"); XCTAssertTrue(marked[1].included)
        XCTAssertEqual(marked[1].entry().sourceID, 1)
        XCTAssertNotNil(ListImport.shikimoriURL("Иван 1")); XCTAssertNil(ListImport.shikimoriURL("a/b"))
    }

    func testDiaryNotesDoNotReplaceTheResumePoint() throws {
        var e = Entry(title: "Тайтл", episode: 5)
        e.addNote(EpisodeNote(episode: 4, time: "12:30", text: "", createdAt: Date(timeIntervalSince1970: 100)))
        e.addNote(EpisodeNote(episode: 5, createdAt: Date(timeIntervalSince1970: 200), rating: 4))
        XCTAssertEqual(e.resumePoint?.time, "12:30")
        XCTAssertTrue(e.notes!.last!.isDiary)
        var s = Snapshot(); s.entries = [e]
        XCTAssertEqual(try Snapshot.decode(try s.encoded()).entries[0].notes?.last?.rating, 4)
    }
}
