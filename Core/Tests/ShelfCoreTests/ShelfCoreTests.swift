import XCTest
@testable import ShelfCore

final class ShelfCoreTests: XCTestCase {
    func repository() throws -> ShelfRepository { try ShelfRepository(url:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shelf.json")) }
    func testProgressUndoAndRelaunch() throws {
        let r = try repository(); var state = Snapshot(); let e = Entry(title:"История",episode:24); state.entries = [e]; try r.commit(state)
        let undo = try XCTUnwrap(r.increment(e.id,now:Date(timeIntervalSince1970:1000)))
        XCTAssertEqual(r.snapshot.entries[0].episode,25)
        XCTAssertEqual(try ShelfRepository(url:r.url).snapshot.entries[0].episode,25)
        try r.undo(undo); XCTAssertEqual(r.snapshot.entries[0],e)
        XCTAssertEqual(try ShelfRepository(url:r.url).snapshot.entries[0].episode,24)
    }
    func testUndoDoesNotClobberNewerEditsOrSecondIncrement() throws {
        let r = try repository(); var s = Snapshot(); let e = Entry(title:"История"); s.entries = [e]; try r.commit(s)
        let first = try XCTUnwrap(r.increment(e.id)); let second = try XCTUnwrap(r.increment(e.id))
        try r.undo(first); XCTAssertEqual(r.snapshot.entries[0].episode,2)
        try r.undo(second); XCTAssertEqual(r.snapshot.entries[0].episode,1)
    }
    func testFailedValidationNeverChangesSavedOrInMemoryState() throws {
        let r = try repository(); var s = Snapshot(); s.entries = [Entry(title:"Сохранённая")]; try r.commit(s)
        let bytes = try Data(contentsOf:r.url); var broken = s; broken.entries[0].episode = -1
        XCTAssertThrowsError(try r.commit(broken)); XCTAssertEqual(r.snapshot,s); XCTAssertEqual(try Data(contentsOf:r.url),bytes)
        XCTAssertThrowsError(try Snapshot.decode(Data("broken".utf8))); XCTAssertEqual(try Data(contentsOf:r.url),bytes)
    }
    func testUndoPreservesBackgroundCoverAndUnrelatedEdits() throws {
        let r = try repository(); var s = Snapshot(); let e = Entry(title:"История",episode:24); s.entries = [e]; try r.commit(s)
        let token = try XCTUnwrap(r.increment(e.id)); var next = r.snapshot
        next.entries[0].coverData = Data([1,2]); next.entries[0].favorite = true; try r.commit(next)
        try r.undo(token); XCTAssertEqual(r.snapshot.entries[0].episode,24)
        XCTAssertEqual(r.snapshot.entries[0].coverData,Data([1,2])); XCTAssertTrue(r.snapshot.entries[0].favorite)
    }
    func testFailedDiskWriteNeverPublishesState() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let r = try ShelfRepository(url:path.appendingPathComponent("shelf.json"))
        try Data([1]).write(to:path) // Parent is a file, so saving cannot succeed.
        var next = Snapshot(); next.entries = [Entry(title:"Не сохранится")]
        XCTAssertThrowsError(try r.commit(next)); XCTAssertTrue(r.snapshot.entries.isEmpty)
    }
    func testBackupRoundtripIncludesImagesSettingsOrderAndOptionalSeason() throws {
        var s = Snapshot(); var a = Entry(title:"Личное название",episode:150); a.coverData = Data([1,2,3]); a.season = nil; a.note = "Заметка"; a.favorite = true; a.watchURL = "https://example.org/watch"
        var b = Entry(title:"Вторая"); b.season = 2; b.status = .dropped
        s.entries = [b,a]; s.preferences.wifiOnly = true; s.preferences.theme = .light; s.preferences.sort = .manual; s.preferences.layout = .grid
        XCTAssertEqual(try Snapshot.decode(s.encoded()),s)
    }
    func testRejectUnsupportedDuplicateAndInvalidBackup() throws {
        var s = Snapshot(); s.version = 200; XCTAssertThrowsError(try s.encoded()); s.version = 1
        let e = Entry(title:"Повтор"); s.entries = [e,e]; XCTAssertThrowsError(try s.encoded())
        s.entries = [Entry(title:" ")]; XCTAssertThrowsError(try s.encoded())
        s.entries = [Entry(title:"Серия",episode:1_000_001)]; XCTAssertThrowsError(try s.encoded())
    }
    func testImportKeepsSpellingStarsAndUnrecognizedOriginal() {
        let rows = TextListParser.parse("Мой дракон⭐ 24\nИсходнае название\nИстория — 150 серий\n86\nДругая 2\n\n")
        XCTAssertEqual(rows.count,5); XCTAssertEqual(rows[0].title,"Мой дракон⭐"); XCTAssertEqual(rows[0].episode,24); XCTAssertTrue(rows[0].favorite)
        XCTAssertEqual(rows[1].title,"Исходнае название"); XCTAssertFalse(rows[1].recognized); XCTAssertEqual(rows[1].episode,0)
        XCTAssertEqual(rows[2].episode,150); XCTAssertEqual(rows[3].title,"86"); XCTAssertFalse(rows[3].recognized)
    }
    func testSortingFiltersAndRealManualOrder() throws {
        var s = Snapshot(); var a = Entry(title:"Альфа"); a.status = .planned; a.favorite = true
        var b = Entry(title:"Бета"); b.watchedAt = Date(timeIntervalSince1970:500); b.note = "Тайная заметка"
        s.entries = [b,a]; s.preferences.sort = .title; XCTAssertEqual(s.visible().map(\.title),["Альфа","Бета"])
        XCTAssertEqual(s.visible(status:.planned,favorites:true).map(\.id),[a.id]); XCTAssertEqual(s.visible(query:"ТАЙНАЯ").map(\.id),[b.id])
        s.preferences.sort = .manual; s.reorder(ids:[a.id,b.id]); XCTAssertEqual(s.visible().map(\.id),[a.id,b.id])
        s.preferences.sort = .recent; XCTAssertEqual(s.visible().first?.id,b.id)
        let r = try repository(); try r.commit(s); XCTAssertEqual(try ShelfRepository(url:r.url).snapshot.entries.map(\.id),[a.id,b.id])
    }
    func testMergePreservesCurrentProgressAndAddsNewRecords() {
        var current = Snapshot(); let e = Entry(title:"Существующая",episode:50); current.entries = [e]
        var copy = Snapshot(); var older = e; older.episode = 20; let other = Entry(title:"Другая"); copy.entries = [older,other]; copy.preferences.theme = .light
        current.merge(copy); XCTAssertEqual(current.entries,[e,other]); XCTAssertEqual(current.preferences.theme,.dark)
    }
    func testNetworkPolicyForAllCombinations() {
        for connected in [true,false] { for wifi in [true,false] { for restricted in [true,false] {
            XCTAssertEqual(CoverPolicy.permits(wifiOnly:restricted,connected:connected,wifi:wifi),connected && (!restricted || wifi))
        } } }
    }
    func testUpperBoundDoesNotOverflowProgress() throws {
        let r = try repository(); var s = Snapshot(); let e = Entry(title:"Граница",episode:1_000_000); s.entries = [e]; try r.commit(s)
        XCTAssertNil(try r.increment(e.id)); XCTAssertEqual(r.snapshot,s)
    }
}
