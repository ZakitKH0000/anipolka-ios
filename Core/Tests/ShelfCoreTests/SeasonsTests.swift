import XCTest
@testable import ShelfCore

final class SeasonsTests: XCTestCase {
    func part(_ id: Int, _ title: String, episodes: Int?, status: String = Airing.released, aired: String) -> FranchisePart {
        FranchisePart(id: id, title: title, originalTitle: title, kind: "ona", episodes: episodes, status: status, airedOn: aired, coverURL: "")
    }
    /// «За гранью времени»: Shikimori gives no franchise, only a sequel; 26 + 52 episodes.
    func snapshot(episode: Int) -> (Snapshot, UUID) {
        let info = FranchiseInfo(key: "chain-62340", parts: [part(64398, "За гранью времени 2", episodes: 52, status: Airing.ongoing, aired: "2026-06-20"),
                                                             part(62340, "За гранью времени", episodes: 26, aired: "2025-12-28")].sorted { $0.airedOn! < $1.airedOn! },
                                 checkedAt: Date())
        var s = Snapshot(); s.franchises = [info]
        var e = Entry(title: "За гранью времени", episode: episode); e.sourceID = 62340; e.franchise = info.key
        s.entries = [e]
        return (s, e.id)
    }

    func testChainIsBuiltFromPrequelsAndSequels() throws {
        let json = #"{"data":{"animes":[{"id":"64398","name":"Guangyin Zhi Wai 2","russian":"За гранью времени 2","kind":"ona","episodes":52,"status":"ongoing","airedOn":{"date":"2026-06-20"},"poster":null,"related":[{"relationKind":"prequel","anime":{"id":"62340"}},{"relationKind":"alternative_setting","anime":{"id":"41923"}}]},{"id":"62340","name":"Guangyin Zhi Wai","russian":"За гранью времени","kind":"ona","episodes":26,"status":"released","airedOn":{"date":"2025-12-28"},"poster":{"mainUrl":"https://x/p.jpg"},"related":[{"relationKind":"sequel","anime":{"id":"64398"}}]}]}}"#
        let nodes = try FranchiseChain.parse(Data(json.utf8))
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes.first { $0.part.id == 64398 }?.neighbours, [62340])
        let info = try XCTUnwrap(FranchiseChain.assemble(nodes))
        XCTAssertEqual(info.key, "chain-62340"); XCTAssertEqual(info.parts.map(\.id), [62340, 64398])
        XCTAssertTrue(FranchiseChain.isChain(info.key))
    }

    func testNumberPastTheSeasonPointsToTheNextOne() throws {
        let (s, id) = snapshot(episode: 48)
        let e = s.entries[0]
        let over = try XCTUnwrap(Franchise.overflow(e, in: s))
        XCTAssertEqual(over.season, 2); XCTAssertEqual(over.episode, 22); XCTAssertEqual(over.offset, 26); XCTAssertEqual(over.part.id, 64398)
        XCTAssertEqual(Franchise.seasonLine(e, in: s), "сезон 2 · серия 22")
        // Inside the first season nothing is suggested.
        XCTAssertNil(Franchise.overflow(snapshot(episode: 20).0.entries[0], in: snapshot(episode: 20).0))
        XCTAssertEqual(Franchise.seasonLine(snapshot(episode: 20).0.entries[0], in: snapshot(episode: 20).0), "сезон 1")

        var moved = s
        Franchise.move(&moved, entryID: id, to: over)
        let m = moved.entries[0]
        XCTAssertEqual(m.sourceID, 64398); XCTAssertEqual(m.episode, 48); XCTAssertEqual(m.seasonEpisode, 22); XCTAssertEqual(m.episodeOffset, 26)
        XCTAssertEqual(m.season, 2); XCTAssertEqual(m.title, "За гранью времени")
        XCTAssertEqual(moved.franchises?.first?.absolute, true)
        XCTAssertNil(Franchise.overflow(m, in: moved))
        XCTAssertEqual(Franchise.seasonLine(m, in: moved), "сезон 2 · серия 22")
        XCTAssertNil(Franchise.seasonMismatch(m, in: moved))
        XCTAssertEqual(try Snapshot.decode(moved.encoded()), moved)
    }

    func testThroughCountingSourceAndWatchedSeasonsAfterTheMove() throws {
        var (s, id) = snapshot(episode: 48)
        // AniVibe counted through seasons while the entry was season 1: 48 > 26.
        s.entries[0].subscriptions = [ReleaseSubscription(pageURL: "https://anivibe.pro/anime/1", optionID: "kodik-1-1", label: "Студия", episode: 48)]
        let over = try XCTUnwrap(Franchise.overflow(s.entries[0], in: s))
        Franchise.move(&s, entryID: id, to: over)
        XCTAssertEqual(s.entries[0].subscriptions?.first?.offset, 26)
        XCTAssertNil(Backlog.available(s.entries[0]))
        let info = try XCTUnwrap(s.franchises?.first)
        XCTAssertTrue(Franchise.covered(info.parts[0], in: info, snapshot: s))
        XCTAssertFalse(Franchise.covered(info.parts[1], in: info, snapshot: s))
        XCTAssertEqual(Franchise.watched(in: info, snapshot: s), 48)
        // Adding season 1 later creates it as already watched.
        let added = Franchise.entry(for: info.parts[0], after: s.entries[0], in: info, status: .watching)
        XCTAssertEqual(added.status, .completed); XCTAssertEqual(added.episode, 26)
    }

    func testAlignSourcesRepairsAnEntryMovedBefore() {
        var e = Entry(title: "За гранью времени", episode: 48); e.episodeOffset = 26
        e.airing = AiringInfo(checkedAt: Date(), status: Airing.ongoing, episodes: 52, episodesAired: 22)
        e.subscriptions = [ReleaseSubscription(pageURL: "https://anivibe.pro/anime/1", optionID: "kodik-1-1", label: "Студия", episode: 48)]
        XCTAssertEqual(Backlog.available(e), 26)
        XCTAssertTrue(Franchise.alignSources(&e))
        XCTAssertNil(Backlog.available(e))
        // A source counting inside the season is left alone.
        var inside = e; inside.subscriptions![0].offset = nil; inside.subscriptions![0].lastEpisode = 22
        XCTAssertFalse(Franchise.alignSources(&inside))
    }

    func testOverflowIsNotSuggestedWhenTheNextSeasonIsAlreadyInTheCollection() {
        var (s, _) = snapshot(episode: 48)
        var second = Entry(title: "За гранью времени 2", episode: 3); second.sourceID = 64398; second.franchise = "chain-62340"
        s.entries.append(second)
        XCTAssertNil(Franchise.overflow(s.entries[0], in: s))
    }
}
