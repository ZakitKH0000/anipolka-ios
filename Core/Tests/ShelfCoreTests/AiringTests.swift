import XCTest
@testable import ShelfCore

final class AiringTests: XCTestCase {
    private var kyiv: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Kiev")!; return c }

    private func notice(_ source: ReleaseSubscription, _ episode: Int, _ at: Date, read: Bool = false) -> ReleaseNotice {
        var s = source; s.lastEpisode = episode - 1
        var n = ReleaseNotice(subscription: s, entryTitle: "Тайтл", episode: episode, url: "https://anivibe.pro/anime/x", now: at)
        n.read = read
        return n
    }

    func testWatchedEpisodesMarkNoticesReadAndOldReadOnesExpire() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let source = ReleaseSubscription(pageURL: "https://anivibe.pro/anime/x", optionID: "o", label: "ПВА", episode: 4)
        var e = Entry(title: "Тайтл", episode: 7)
        let old = now.addingTimeInterval(-40 * 86400)
        e.releaseNotices = [notice(source, 8, now), notice(source, 7, now), notice(source, 6, old, read: true), notice(source, 5, old)]
        let tidy = NoticeInbox.tidy(e, now: now)
        XCTAssertEqual(tidy.releaseNotices?.map(\.episode), [8, 7])
        XCTAssertEqual(tidy.releaseNotices?.map(\.read), [false, true])
        var s = Snapshot(); s.entries = [tidy]
        XCTAssertEqual(NoticeInbox.unread(s), 1)
        var all = s; NoticeInbox.markAllRead(&all); XCTAssertEqual(NoticeInbox.unread(all), 0)
        var cleared = s; NoticeInbox.removeRead(&cleared); XCTAssertEqual(cleared.entries[0].releaseNotices?.count, 1)
        var empty = s; NoticeInbox.removeAll(&empty); XCTAssertEqual(empty.entries[0].releaseNotices?.count, 0)
    }

    func testReadsBroadcastDataAndSequelFromShikimori() throws {
        let json = #"""
        {"data":{"animes":[{"id":"52991","status":"released","episodes":28,"episodesAired":27,"nextEpisodeAt":null,
        "related":[{"relationKind":"sequel","anime":{"id":"59978","name":"Sousou no Frieren 2nd Season","russian":"Провожающая в последний путь Фрирен 2","status":"anons","kind":"tv","airedOn":{"date":"2026-01-16"},"poster":{"mainUrl":"https://shikimori.io/p.webp"}}},
        {"relationKind":"other","anime":{"id":"1","name":"Song","russian":"","status":"released","kind":"music"}}]},
        {"id":"21","status":"ongoing","episodes":0,"episodesAired":1180,"nextEpisodeAt":"2026-11-22T17:15:00+03:00","related":[]}]}}
        """#
        let now = ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z")!
        let found = try Airing.parse(Data(json.utf8), now: now)
        let frieren = try XCTUnwrap(found[52991])
        XCTAssertEqual(frieren.episodes, 28); XCTAssertNil(frieren.nextEpisodeAt)
        XCTAssertEqual(frieren.sequel?.id, 59978); XCTAssertEqual(frieren.sequel?.title, "Провожающая в последний путь Фрирен 2")
        let onePiece = try XCTUnwrap(found[21])
        XCTAssertNil(onePiece.episodes); XCTAssertEqual(onePiece.episodesAired, 1180)
        XCTAssertEqual(onePiece.nextEpisodeAt, ISO8601DateFormatter().date(from: "2026-11-22T14:15:00Z"))

        var base = Entry(title: "Ван-Пис", episode: 1175); base.sourceID = 21
        let watching = Airing.apply(base, onePiece, calendar: kyiv)
        XCTAssertEqual(watching.releaseDays, [1])
        XCTAssertEqual(Airing.nextEpisode(watching, now: now), 1181)
        XCTAssertEqual(Airing.aired(watching), 5)
        XCTAssertEqual(Airing.countdown(onePiece.nextEpisodeAt!, now: now), "через 1 д 4 ч")
        let days = Airing.calendar([watching], now: now, calendar: kyiv)
        XCTAssertEqual(days[1].items.first?.episode, 1181)
        XCTAssertTrue(days[0].items.isEmpty)

        var done = Entry(title: "Фрирен", episode: 28); done.status = .completed; done.sourceID = 52991
        done = Airing.apply(done, frieren, calendar: kyiv)
        var s = Snapshot(); s.entries = [done]
        let hint = try XCTUnwrap(Airing.sequelSuggestion(done, in: s))
        var dismissed = done; dismissed.dismissedSequelID = hint.id
        XCTAssertNil(Airing.sequelSuggestion(dismissed, in: s))
        s.entries.append(Airing.sequelEntry(hint, after: done.id))
        XCTAssertNil(Airing.sequelSuggestion(done, in: s))
        XCTAssertEqual(s.entries[1].relatedIDs, [done.id])

        // The new fields survive a backup round trip and older copies without them still open.
        let copy = try Snapshot.decode(try s.encoded())
        XCTAssertEqual(copy.entries[0].airing, done.airing)
        let legacy = try Snapshot.decode(Data(#"{"format":"AniPolka","version":1,"entries":[],"preferences":{}}"#.utf8))
        XCTAssertTrue(legacy.preferences.catalogUpdates); XCTAssertFalse(legacy.preferences.airingReminders)
    }
}
