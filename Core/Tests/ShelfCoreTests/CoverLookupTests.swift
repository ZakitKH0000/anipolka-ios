import XCTest
@testable import ShelfCore

final class CoverLookupTests: XCTestCase {
    let missing = "https://shikimori.io/assets/globals/missing_original.jpg"
    let primaryURL = "https://shikimori.io/uploads/poster/animes/60416/poster.jpg"
    let fallbackURL = "https://media.kitsu.app/anime/123/poster_image/large.jpg"
    let bytes = Data([0xff,0xd8,0xff,0xd9]) // The resolver receives bytes already decoded/normalised by NetworkService.

    func candidate(url: String, catalog: AnimeCatalog = .shikimori, name: String = "Wu Lian Dianfeng", year: String? = "2024-12-05", kind: String = "ona") -> AnimeCandidate {
        AnimeCandidate(id:catalog == .shikimori ? 60416 : 123,name:name,russian:catalog == .shikimori ? "Пик боевых искусств" : nil,image:.init(original:url,preview:url),url:catalog == .shikimori ? "/animes/60416-wu-lian-dianfeng" : "https://kitsu.app/anime/wu-lian-dianfeng",kind:kind,episodes:48,aired_on:year,catalog:catalog)
    }
    func testPlaceholderAndNonImageResponsesAreNotPosters() {
        for value in [missing,"https://shikimori.io/assets/globals/missing_preview.jpg?v=1","https://shikimori.io/assets/globals/%6dissing_x96.jpg"] {
            XCTAssertTrue(CoverImagePolicy.isPlaceholder(value)); XCTAssertNil(CoverImagePolicy.usableURL(value))
            XCTAssertFalse(CoverImagePolicy.acceptsResponse(status:200,mimeType:"image/jpeg",url:value))
        }
        XCTAssertEqual(candidate(url:missing).posterURL,"")
        XCTAssertEqual(candidate(url:"").posterURL,"")
        XCTAssertFalse(CoverImagePolicy.acceptsResponse(status:404,mimeType:"image/jpeg",url:primaryURL))
        XCTAssertFalse(CoverImagePolicy.acceptsResponse(status:200,mimeType:"text/html",url:primaryURL))
        XCTAssertFalse(CoverImagePolicy.acceptsResponse(status:200,mimeType:nil,url:primaryURL))
        XCTAssertTrue(CoverImagePolicy.acceptsResponse(status:200,mimeType:"image/webp",url:primaryURL))
    }
    func testGraphQLUsesNewPosterAndHandlesNullPosterAndErrors() throws {
        let json = #"{"data":{"animes":[{"id":"60416","name":"Wu Lian Dianfeng","russian":"Пик боевых искусств","url":"/animes/60416-wu-lian-dianfeng","kind":"ona","episodes":48,"airedOn":{"year":2024,"month":12,"day":5},"poster":{"originalUrl":"https://shikimori.io/uploads/poster/animes/60416/poster.jpg","mainUrl":"https://shikimori.io/uploads/poster/animes/60416/main.webp"}}]}}"#
        let decoded = try JSONDecoder().decode(ShikimoriGraphQLResponse.self,from:Data(json.utf8)).candidates()
        XCTAssertEqual(decoded.first?.posterURL,primaryURL); XCTAssertEqual(decoded.first?.aired_on,"2024-12-05")
        let noPoster = json.replacingOccurrences(of:#"{"originalUrl":"https://shikimori.io/uploads/poster/animes/60416/poster.jpg","mainUrl":"https://shikimori.io/uploads/poster/animes/60416/main.webp"}"#,with:"null")
        XCTAssertEqual(try JSONDecoder().decode(ShikimoriGraphQLResponse.self,from:Data(noPoster.utf8)).candidates().first?.posterURL,"")
        let error = Data(#"{"data":null,"errors":[{"message":"unavailable"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ShikimoriGraphQLResponse.self,from:error).candidates())
    }
    @MainActor func testHTTP200PlaceholderTriggersKitsuAndPreservesShikimoriIdentity() async throws {
        let primary = candidate(url:missing), secondary = candidate(url:fallbackURL,catalog:.kitsu)
        var calls: [AnimeCatalog] = []; var downloads: [String] = []
        let result = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Пик боевых искусств",episode:48),search:{ query,catalog in
            calls.append(catalog)
            if catalog == .kitsu { XCTAssertEqual(query,"Wu Lian Dianfeng") }
            return [catalog == .shikimori ? primary : secondary]
        },lookup:{ _ in XCTFail("Unselected title must use search"); return nil },download:{ url in downloads.append(url); return self.bytes })
        guard case .found(let found) = result else { return XCTFail("Expected fallback poster") }
        XCTAssertEqual(calls,[.shikimori,.kitsu]); XCTAssertEqual(downloads,[fallbackURL])
        XCTAssertEqual(found.url,fallbackURL); XCTAssertEqual(found.imageCatalog,.kitsu)
        XCTAssertEqual(found.candidate?.shikimoriID,60416); XCTAssertEqual(found.candidate?.pageURL,primary.pageURL)
    }
    @MainActor func testFailedDownloadFallsBackButSuccessfulPrimaryDoesNotQueryKitsu() async throws {
        for fails in [true,false] {
            var calls: [AnimeCatalog] = []
            let result = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Пик боевых искусств"),search:{ _,catalog in
                calls.append(catalog); return [self.candidate(url:catalog == .shikimori ? self.primaryURL : self.fallbackURL,catalog:catalog)]
            },lookup:{ _ in nil },download:{ url in
                if fails && url == self.primaryURL { throw URLError(.badServerResponse) }
                return self.bytes
            })
            guard case .found(let found) = result else { return XCTFail("Poster not resolved") }
            XCTAssertEqual(found.url,fails ? fallbackURL : primaryURL)
            XCTAssertEqual(calls,fails ? [.shikimori,.kitsu] : [.shikimori])
        }
    }
    @MainActor func testMissingImageAndCatalogOutageAlsoReachKitsu() async throws {
        for outage in [false,true] {
            let result = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Wu Lian Dianfeng"),search:{ _,catalog in
                if catalog == .shikimori && outage { throw URLError(.cannotConnectToHost) }
                return [self.candidate(url:catalog == .shikimori ? "" : self.fallbackURL,catalog:catalog)]
            },lookup:{ _ in nil },download:{ _ in self.bytes })
            guard case .found(let found) = result else { return XCTFail("Expected Kitsu fallback") }
            XCTAssertEqual(found.url,fallbackURL)
        }
    }
    @MainActor func testFallbackRejectsAnotherSeasonYearAndAmbiguousMatches() async throws {
        let invalidGroups = [
            [candidate(url:fallbackURL,catalog:.kitsu,name:"Wu Lian Dianfeng 2")],
            [candidate(url:fallbackURL,catalog:.kitsu,year:"2026-01-01")],
            [candidate(url:fallbackURL,catalog:.kitsu,year:nil)],
            [candidate(url:fallbackURL,catalog:.kitsu,kind:"movie")],
            [candidate(url:fallbackURL,catalog:.kitsu),candidate(url:fallbackURL,catalog:.kitsu)]
        ]
        for group in invalidGroups {
            let result = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Пик боевых искусств"),search:{ _,catalog in
                catalog == .shikimori ? [self.candidate(url:self.missing)] : group
            },lookup:{ _ in nil },download:{ _ in XCTFail("Do not download an unrelated or ambiguous poster"); return self.bytes })
            guard case .notFound = result else { return XCTFail("Must not choose another edition") }
        }
    }
    @MainActor func testKitsuOriginalTitleAliasCanMatchCanonicalEnglishTitle() async throws {
        var secondary = candidate(url:fallbackURL,catalog:.kitsu,name:"Martial Peak")
        secondary.aliases = ["Wu Lian Dianfeng"]
        let result = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Пик боевых искусств"),search:{ _,catalog in
            catalog == .shikimori ? [self.candidate(url:self.missing)] : [secondary]
        },lookup:{ _ in nil },download:{ _ in self.bytes })
        guard case .found(let found) = result else { return XCTFail("Original title alias was ignored") }
        XCTAssertEqual(found.url,fallbackURL)
    }
    @MainActor func testSelectedIDIsUsedEvenWithCustomTitleAndBrokenSavedURL() async throws {
        var entry = Entry(title:"Моё привычное название",episode:48)
        entry.sourceID = 60416; entry.originalTitle = "Wu Lian Dianfeng"; entry.coverURL = primaryURL
        var downloads: [String] = []
        let result = try await AutomaticCoverLookup.resolve(entry:entry,search:{ query,catalog in
            XCTAssertEqual(catalog,.kitsu); XCTAssertEqual(query,"Wu Lian Dianfeng")
            return [self.candidate(url:self.fallbackURL,catalog:.kitsu)]
        },lookup:{ id in XCTAssertEqual(id,60416); return self.candidate(url:self.primaryURL) },download:{ url in
            downloads.append(url); if url == self.primaryURL { throw URLError(.cannotDecodeContentData) }; return self.bytes
        })
        guard case .found(let found) = result else { return XCTFail("Expected replacement poster") }
        XCTAssertEqual(found.candidate?.shikimoriID,60416)
        XCTAssertEqual(downloads,[primaryURL,fallbackURL])
    }
    @MainActor func testSelectedIDWithoutConfirmedNameNeverFallsBackToUserTitle() async throws {
        var entry = Entry(title:"Пик боевых искусств"); entry.sourceID = 60416
        let result = try await AutomaticCoverLookup.resolve(entry:entry,search:{ _,_ in
            XCTFail("Unconfirmed identity must not search by the user's title"); return [self.candidate(url:self.fallbackURL,catalog:.kitsu)]
        },lookup:{ _ in throw URLError(.timedOut) },download:{ _ in self.bytes })
        guard case .notFound(let needsChoice) = result else { return XCTFail("Must retry later") }
        XCTAssertFalse(needsChoice)
        var snapshot = Snapshot(); snapshot.entries = [entry]
        let kitsuOnly = ResolvedCover(candidate:candidate(url:fallbackURL,catalog:.kitsu),url:fallbackURL,data:bytes,imageCatalog:.kitsu)
        XCTAssertTrue(snapshot.applyResolvedCover(kitsuOnly,to:entry))
        XCTAssertEqual(snapshot.entries[0].sourceID,60416); XCTAssertEqual(snapshot.entries[0].originalTitle,"")
    }
    @MainActor func testCancellationDoesNotTriggerFallback() async throws {
        var calls: [AnimeCatalog] = []
        do {
            _ = try await AutomaticCoverLookup.resolve(entry:Entry(title:"Пик боевых искусств"),search:{ _,catalog in
                calls.append(catalog); return [self.candidate(url:self.primaryURL)]
            },lookup:{ _ in nil },download:{ _ in throw CancellationError() })
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls,[.shikimori])
    }
    func testMigrationAndAtomicReplacementPreserveProgressAndRespectManualChanges() throws {
        var snapshot = Snapshot()
        var broken = Entry(title:"Моё название",episode:48)
        broken.coverURL = missing; broken.coverData = bytes; broken.sourceID = 60416
        broken.originalTitle = "Wu Lian Dianfeng"; broken.note = "Моя заметка"; broken.favorite = true
        broken.season = 1; broken.watchedAt = Date(timeIntervalSince1970:100)
        var photo = Entry(title:"Своя обложка"); photo.coverData = bytes; photo.coverLookupDisabled = true
        snapshot.entries = [broken,photo]
        XCTAssertTrue(snapshot.removePlaceholderCovers()); XCTAssertFalse(snapshot.removePlaceholderCovers())
        var expected = broken; expected.coverURL = ""; expected.coverData = nil
        XCTAssertEqual(snapshot.entries,[expected,photo]); XCTAssertEqual(try Snapshot.decode(snapshot.encoded()),snapshot)
        let before = snapshot.entries[0]
        let cover = ResolvedCover(candidate:candidate(url:primaryURL),url:fallbackURL,data:bytes,imageCatalog:.kitsu)
        // Progress can advance while the request is in flight; only cover metadata changes.
        snapshot.entries[0].episode = 49
        XCTAssertTrue(snapshot.applyResolvedCover(cover,to:before))
        XCTAssertEqual(snapshot.entries[0].episode,49); XCTAssertEqual(snapshot.entries[0].title,broken.title)
        XCTAssertEqual(snapshot.entries[0].note,broken.note); XCTAssertEqual(snapshot.entries[0].watchedAt,broken.watchedAt)
        XCTAssertEqual(snapshot.entries[0].updatedAt,broken.updatedAt); XCTAssertEqual(snapshot.entries[0].season,1)
        XCTAssertTrue(snapshot.entries[0].favorite); XCTAssertEqual(snapshot.entries[1],photo)
        XCTAssertEqual(snapshot.entries[0].sourceID,60416); XCTAssertEqual(snapshot.entries[0].coverData,bytes)
        XCTAssertEqual(try Snapshot.decode(snapshot.encoded()),snapshot)
        // A later manual image, deletion, rename or opt-out must defeat an old request.
        for change in 0..<4 {
            var changed = Snapshot(); changed.entries = [before]
            if change == 0 { changed.entries[0].coverData = bytes }
            if change == 1 { changed.entries.removeAll() }
            if change == 2 { changed.entries[0].title = "Другое произведение" }
            if change == 3 { changed.entries[0].coverLookupDisabled = true }
            let saved = changed
            XCTAssertFalse(changed.applyResolvedCover(cover,to:before)); XCTAssertEqual(changed,saved)
        }
    }
}
