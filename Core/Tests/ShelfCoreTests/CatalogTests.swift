import XCTest
@testable import ShelfCore

final class CatalogTests: XCTestCase {
    func testDetailsTextVideosAndRating() throws {
        let json = #"""
        {"data":{"animes":[{"id":"52991","score":9.29,"rating":"pg_13","duration":24,
        "description":"Отряд героя [character=186854]Химмеля[/character] вернулся домой.\r\nВолшебница [character=1]Фрирен[/character].",
        "genres":[{"russian":"Приключения"},{"russian":"Драма"}],"studios":[{"name":"Madhouse"}],
        "videos":[{"url":"https://youtu.be/a","name":"23","kind":"episode_preview"},{"url":"https://youtu.be/b","name":"PV1","kind":"pv"},{"url":"javascript:x","name":"x","kind":"pv"}],
        "screenshots":[{"originalUrl":"https://shikimori.io/o.jpg","x332Url":"https://shikimori.io/s.jpg"}]}]}}
        """#
        let d = try XCTUnwrap(Catalog.parseDetails(Data(json.utf8)))
        XCTAssertEqual(d.description, "Отряд героя Химмеля вернулся домой.\nВолшебница Фрирен.")
        XCTAssertEqual(d.genres, ["Приключения", "Драма"]); XCTAssertEqual(d.studios, ["Madhouse"])
        XCTAssertEqual(d.ratingLabel, "12+"); XCTAssertEqual(d.duration, 24)
        XCTAssertEqual(d.videos.map(\.url), ["https://youtu.be/b", "https://youtu.be/a"])
        XCTAssertEqual(d.videos.first?.title, "Трейлер PV1")
        XCTAssertEqual(d.screenshots, ["https://shikimori.io/s.jpg"]); XCTAssertEqual(d.screenshotsFull, ["https://shikimori.io/o.jpg"])
    }

    func testSimilarAndShelfItemsBecomeEntries() throws {
        let similar = #"[{"id":33352,"name":"Violet Evergarden","russian":"Вайолет Эвергарден","kind":"tv","score":"8.69","episodes":13,"status":"released","aired_on":"2018-01-11","image":{"original":"/system/animes/original/33352.jpg?1"}}]"#
        let item = try XCTUnwrap(Catalog.parseSimilar(Data(similar.utf8)).first)
        XCTAssertEqual(item.posterURL, "https://shikimori.io/system/animes/original/33352.jpg?1")
        XCTAssertEqual(item.score, 8.69)
        XCTAssertEqual(item.line, "Сериал · 2018 · 13 серий · ★ 8.7")
        let entry = item.entry(status: .planned)
        XCTAssertEqual(entry.sourceID, 33352); XCTAssertEqual(entry.title, "Вайолет Эвергарден"); XCTAssertEqual(entry.status, .planned)
        XCTAssertEqual(entry.aliases, ["Violet Evergarden"])

        let shelf = #"{"data":{"animes":[{"id":"21","name":"One Piece","russian":"Ван-Пис","kind":"tv","episodes":0,"episodesAired":1180,"status":"ongoing","score":8.7,"airedOn":{"date":"1999-10-20"},"poster":{"mainUrl":"https://shikimori.io/p.webp"}},{"id":"9","name":"Song","russian":"","kind":"music","status":"released"}]}}"#
        let items = try Catalog.parseItems(Data(shelf.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].line, "Сериал · 1999 · выходит · 1180 из ? · ★ 8.7")
    }
}
