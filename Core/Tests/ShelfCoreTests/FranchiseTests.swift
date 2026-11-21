import XCTest
@testable import ShelfCore

final class FranchiseTests: XCTestCase {
    private let json = #"""
    {"data":{"animes":[
    {"id":"50444","name":"Yong Sheng","russian":"Бессмертие","kind":"ona","episodes":12,"status":"released","airedOn":{"date":"2022-01-29"},"poster":{"mainUrl":"https://shikimori.io/a.webp"}},
    {"id":"55684","name":"Yong Sheng 2","russian":"Бессмертие: Десятилетнее соглашение","kind":"ona","episodes":12,"status":"released","airedOn":{"date":"2023-07-08"},"poster":null},
    {"id":"58448","name":"Yong Sheng 3","russian":"Бессмертие: Величественные горы и реки","kind":"ona","episodes":16,"status":"released","airedOn":{"date":"2024-04-19"},"poster":null},
    {"id":"99999","name":"Yong Sheng Movie","russian":"Бессмертие: Фильм","kind":"movie","episodes":1,"status":"anons","airedOn":{"date":"2030-01-01"},"poster":null},
    {"id":"1","name":"Song","russian":"","kind":"music","episodes":1,"status":"released","airedOn":{"date":"2022-01-01"},"poster":null}
    ]}}
    """#

    private func setup() throws -> Snapshot {
        let info = try Franchise.parse(Data(json.utf8), key: "yong_sheng")
        var s = Snapshot(); s.franchises = [info]
        var first = Entry(title: "Бессмертие", episode: 12); first.sourceID = 50444; first.franchise = "yong_sheng"; first.watchedAt = Date(timeIntervalSince1970: 100)
        first.airing = AiringInfo(checkedAt: Date(), status: Airing.released, episodes: 12)
        var third = Entry(title: "Бессмертие 3", episode: 3); third.sourceID = 58448; third.franchise = "yong_sheng"; third.status = .planned
        s.entries = [first, third]
        return s
    }

    func testPartsLabelsGroupingAndNextSeason() throws {
        var s = try setup()
        let info = try XCTUnwrap(s.franchises?.first)
        XCTAssertEqual(info.parts.map(\.id), [50444, 55684, 58448, 99999])
        XCTAssertEqual(info.parts.map { Franchise.label($0, in: info) }, ["Сезон 1", "Сезон 2", "Сезон 3", "Фильм"])
        XCTAssertEqual(Franchise.suggestedOffset(info.parts[2], in: info), 24)
        // One card per franchise: the season being watched stands for the others.
        XCTAssertEqual(Franchise.grouped(s.entries, in: s).map(\.id), [s.entries[0].id])

        let next = try XCTUnwrap(Franchise.nextSeasonPrompt(s.entries[0], in: s))
        XCTAssertEqual(next.id, 55684)
        let newID = try XCTUnwrap(Franchise.startNext(&s, from: s.entries[0].id, next: next))
        let created = try XCTUnwrap(s.entries.first { $0.id == newID })
        XCTAssertEqual(created.status, .watching); XCTAssertEqual(created.franchise, "yong_sheng"); XCTAssertEqual(created.sourceID, 55684)
        XCTAssertEqual(s.entries.first { $0.sourceID == 50444 }?.status, .completed)
        XCTAssertNil(Franchise.nextSeasonPrompt(s.entries.first { $0.sourceID == 50444 }!, in: s))
        XCTAssertEqual(Franchise.grouped(s.entries, in: s).count, 1)
    }

    func testThroughSeasonNumberingKeepsTheSeasonEpisode() throws {
        var s = try setup()
        Franchise.setAbsolute(&s, key: "yong_sheng", absolute: true)
        let third = try XCTUnwrap(s.entries.first { $0.sourceID == 58448 })
        XCTAssertEqual(third.episodeOffset, 24); XCTAssertEqual(third.episode, 27); XCTAssertEqual(third.seasonEpisode, 3)
        Franchise.setOffset(&s, entryID: third.id, offset: 30)
        XCTAssertEqual(s.entries.first { $0.id == third.id }?.episode, 33)
        Franchise.setAbsolute(&s, key: "yong_sheng", absolute: false)
        let back = try XCTUnwrap(s.entries.first { $0.id == third.id })
        XCTAssertEqual(back.episode, 3); XCTAssertNil(back.episodeOffset)
        // Survives a backup round trip.
        Franchise.setAbsolute(&s, key: "yong_sheng", absolute: true)
        let copy = try Snapshot.decode(try s.encoded())
        XCTAssertEqual(copy.franchises?.first?.absolute, true)
        XCTAssertEqual(copy.entries.first { $0.sourceID == 58448 }?.seasonEpisode, 3)
    }

    func testCatchUpBeforeTheNextPart() throws {
        var s = try setup()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2029-12-22T10:00:00Z")!
        s.entries[1].status = .watching
        // Season 3: 13 episodes left, the film premieres in 10 days.
        let plan = try XCTUnwrap(Franchise.catchUp(s.entries[1], in: s, now: now, calendar: cal))
        XCTAssertEqual(plan.remaining, 13); XCTAssertEqual(plan.days, 10); XCTAssertEqual(plan.perDay, 2)
    }

    func testSeasonNumberRebindsToTheRightPart() throws {
        var s = try setup()
        s.entries.remove(at: 1)
        s.entries[0].season = 3; s.entries[0].episode = 3
        let part = try XCTUnwrap(Franchise.seasonMismatch(s.entries[0], in: s))
        XCTAssertEqual(part.id, 58448)
        Franchise.rebind(&s, entryID: s.entries[0].id, to: part)
        XCTAssertEqual(s.entries[0].sourceID, 58448); XCTAssertEqual(s.entries[0].episode, 3); XCTAssertEqual(s.entries[0].title, "Бессмертие")
        XCTAssertNil(s.entries[0].airing)
        XCTAssertNil(Franchise.seasonMismatch(s.entries[0], in: s))
    }

    func testThroughNumberIsKeptWhenSwitchingOn() throws {
        var s = try setup()
        // The user already counts through seasons: 30 in season 3 (16 episodes) means 30 overall.
        s.entries[1].episode = 30
        Franchise.setAbsolute(&s, key: "yong_sheng", absolute: true)
        let third = try XCTUnwrap(s.entries.first { $0.sourceID == 58448 })
        XCTAssertEqual(third.episode, 30); XCTAssertEqual(third.episodeOffset, 24); XCTAssertEqual(third.seasonEpisode, 6)
    }
}
