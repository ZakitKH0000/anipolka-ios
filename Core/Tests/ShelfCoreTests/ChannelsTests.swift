import XCTest
@testable import ShelfCore

final class ChannelsTests: XCTestCase {
    let address = "https://anivibe.pro/anime/44218-test"
    func page(_ episodes: [(Int, Int)]) throws -> SourcePage {
        let rows = episodes.map { ["id": $0.0, "title": "Студия \($0.0)", "last_episode": $0.1, "season": 1] as [String: Any] }
        let json = String(data: try JSONSerialization.data(withJSONObject: ["translations": rows, "material_data": ["anime_title": "История"]]), encoding: .utf8)!
        return try AnivibePageParser.parse("<script>const kodikData = \(json);</script>", url: address)
    }
    func source(_ id: Int, episode: Int, role: SourceRole = .main, offset: Int? = nil) -> ReleaseSubscription {
        var s = ReleaseSubscription(pageURL: address, optionID: "kodik-\(id)-1", label: "Студия \(id)", episode: episode)
        s.role = role == .main ? nil : role.rawValue; s.offset = offset
        return s
    }

    func testBackupRingsOnlyWhenMainIsLateAndOneEpisodeRingsOnce() throws {
        let main = source(1, episode: 10), backup = source(2, episode: 10, role: .backup)
        var entry = Entry(title: "История", episode: 10); entry.subscriptions = [main, backup]
        // The backup is first with episode 11: it rings.
        let early = try XCTUnwrap(ReleaseTracker.observe(try page([(1, 10), (2, 11)]), entry: &entry, subscriptionID: backup.id))
        XCTAssertFalse(early.read)
        // The main dub catches up: the same episode does not ring a second time.
        _ = try ReleaseTracker.observe(try page([(1, 11), (2, 11)]), entry: &entry, subscriptionID: main.id)
        XCTAssertEqual(entry.releaseNotices?.filter { !$0.read }.count, 1)
        // Main first with 12, backup later: the backup is filed as read.
        _ = try ReleaseTracker.observe(try page([(1, 12), (2, 11)]), entry: &entry, subscriptionID: main.id)
        _ = try ReleaseTracker.observe(try page([(1, 12), (2, 12)]), entry: &entry, subscriptionID: backup.id)
        XCTAssertEqual(entry.releaseNotices?.filter { $0.episode == 12 && !$0.read }.count, 1)
        XCTAssertEqual(entry.releaseNotices?.first { $0.episode == 12 && $0.subscriptionID == backup.id }?.read, true)
    }

    func testSilentTrackNeverRings() throws {
        let quiet = source(1, episode: 5, role: .silent)
        var entry = Entry(title: "История", episode: 5); entry.subscriptions = [quiet]
        let notice = try XCTUnwrap(ReleaseTracker.observe(try page([(1, 6)]), entry: &entry, subscriptionID: quiet.id))
        XCTAssertTrue(notice.read)
        XCTAssertEqual(Backlog.available(entry), 1)
    }

    func testOffsetTurnsSourceNumbersIntoTheUsersOwn() throws {
        // The source counts through all seasons: its 168 is the user's 12.
        let s = source(1, episode: 167, offset: 156)
        var entry = Entry(title: "История", episode: 11); entry.subscriptions = [s]
        let notice = try XCTUnwrap(ReleaseTracker.observe(try page([(1, 168)]), entry: &entry, subscriptionID: s.id))
        XCTAssertEqual(notice.episode, 12); XCTAssertEqual(notice.previousEpisode, 11)
        XCTAssertFalse(notice.read)
        XCTAssertEqual(Backlog.available(entry), 1)
        XCTAssertTrue(notice.url.contains("episode=168"))
    }

    func testMirrorKeepsStoredLinksAndRequestsTheMirror() throws {
        XCTAssertEqual(AnivibeMirror.normalizedHost(" https://www.AniVibe.xyz/anime/1 "), "anivibe.xyz")
        XCTAssertNil(AnivibeMirror.normalizedHost("not a host"))
        XCTAssertNil(AnivibeMirror.normalizedHost("https://user@evil.com"))
        AnivibeMirror.host = "anivibe.xyz"; defer { AnivibeMirror.host = AnivibeMirror.defaultHost }
        XCTAssertEqual(AnivibePageParser.canonicalURL("https://anivibe.xyz/anime/42-x")?.absoluteString, "https://anivibe.pro/anime/42-x")
        XCTAssertEqual(AnivibeMirror.live("https://anivibe.pro/anime/42?episode=3"), "https://anivibe.xyz/anime/42?episode=3")
        XCTAssertEqual(AnivibeMirror.live("https://t.me/fumodub/5"), "https://t.me/fumodub/5")
        XCTAssertNil(AnivibePageParser.canonicalURL("https://example.org/anime/42"))
    }

    func testTelegramAddressesAndPosts() throws {
        for value in ["@FumoDub", "FumoDub", "t.me/FumoDub", "https://t.me/s/FumoDub", "https://t.me/FumoDub"] {
            XCTAssertEqual(TelegramChannel.canonicalURL(value)?.absoluteString, "https://t.me/s/FumoDub", value)
        }
        for value in ["https://evil.com/s/FumoDub", "@ab", "https://t.me/FumoDub/12", "javascript:alert(1)"] { XCTAssertNil(TelegramChannel.canonicalURL(value), value) }
        XCTAssertTrue(TelegramChannel.isPostURL("https://t.me/FumoDub/6038"))
        XCTAssertFalse(TelegramChannel.isPostURL("https://t.me/FumoDub"))
        XCTAssertEqual(TelegramChannel.episode(in: "✨ Пощади меня, великий господин! 3\n⚡ Серия: 10-16\n🎙️ Озвучка: S4NN3R"), 16)
        XCTAssertEqual(TelegramChannel.episode(in: "Монолог фармацевта 3 сезон — 8 серия\nГод выхода: 2026\nКоличество серий: 12+"), 8)
        XCTAssertEqual(TelegramChannel.episode(in: "Вышла 12-я серия"), 12)
        XCTAssertNil(TelegramChannel.episode(in: "Step 3 of tutorial"))
        XCTAssertNil(TelegramChannel.episode(in: "Количество серий: 24"))

        let html = """
        <div class="tgme_widget_message_wrap"><div class="tgme_widget_message" data-post="FumoDub/6036"><div class="tgme_widget_message_text js-message_text" dir="auto">✨ Свадьба светлячков<br/>⚡ Серия: 7</div></div></div>
        <div class="tgme_widget_message_wrap"><div class="tgme_widget_message" data-post="FumoDub/6038"><div class="tgme_widget_message_text js-message_text" dir="auto">✨ Пощади меня, великий господин! 3<br/>▫️ Da Wang Rao Ming 3<br/><br/>⚡ Серия: 10-16 &amp; бонус</div></div></div>
        """
        XCTAssertEqual(TelegramChannel.posts(html).count, 2)
        // «▫️» carries an invisible emoji selector right after a space.
        XCTAssertTrue(TelegramChannel.matches("✨\u{FE0F} Пощади меня, великий господин! 3\n▫\u{FE0F} Da Wang Rao Ming 3", keyword: "Пощади меня, великий господин! 3"))
        XCTAssertFalse(TelegramChannel.matches("Пощади меня, великий господин! 3", keyword: "Пощади меня великий господин 2"))
        XCTAssertFalse(TelegramChannel.matches("Пощади меня", keyword: "Пощади меня великий господин"))
        XCTAssertEqual(TelegramChannel.words("Ёж — «Ёлка» 2"), ["еж", "елка", "2"])
        let page = try TelegramChannel.page(html, url: "@FumoDub", keyword: "Пощади меня, великий господин! 3", label: "FumoDub · Telegram")
        XCTAssertEqual(page.options.first?.episode, 16)
        XCTAssertEqual(page.watchURL(for: page.options[0], episode: 16), "https://t.me/FumoDub/6038")
        // A season-1 keyword does not catch the season-3 post.
        XCTAssertThrowsError(try TelegramChannel.page(html, url: "@FumoDub", keyword: "Пощади меня великий господин 2", label: "x"))
        // Without a fresh post the known episode stays, so the counter never rolls back.
        XCTAssertEqual(try TelegramChannel.page(html, url: "@FumoDub", keyword: "Пощади меня, великий господин! 3", label: "x", known: 20).options.first?.episode, 20)

        // A Telegram source is tracked like any other and survives a backup.
        var snapshot = Snapshot(); var entry = Entry(title: "Пощади меня", episode: 15)
        let sub = ReleaseSubscription(pageURL: page.url, optionID: page.options[0].id, label: "FumoDub · Telegram", episode: 15)
        entry.subscriptions = [sub]
        let notice = try XCTUnwrap(ReleaseTracker.observe(page, entry: &entry, subscriptionID: sub.id))
        XCTAssertEqual(notice.url, "https://t.me/FumoDub/6038")
        snapshot.entries = [entry]
        XCTAssertEqual(try Snapshot.decode(snapshot.encoded()), snapshot)
    }

    func testBangumiPicksExactTitleAndCountsEpisodes() throws {
        let search = #"{"results":3,"list":[{"id":607933,"name":"万古至尊：李云霄传","name_cn":"万古至尊"},{"id":466759,"name":"太古神尊","name_cn":"太古神尊"}]}"#
        XCTAssertEqual(Bangumi.pickSubject(Data(search.utf8), native: "太古神尊"), 466759)
        XCTAssertNil(Bangumi.pickSubject(Data(search.utf8), native: "太古"))
        XCTAssertNil(Bangumi.pickSubject(Data(#"{"request":"x","code":404,"error":"Not Found"}"#.utf8), native: "太古神尊"))
        XCTAssertNotNil(Bangumi.searchURL("太古神尊"))
        let episodes = #"{"total":4,"data":[{"ep":35,"sort":35,"airdate":"2026-11-15"},{"ep":36,"sort":36,"airdate":"2026-11-19"},{"ep":37,"sort":37,"airdate":"2026-11-22"},{"ep":38,"sort":38,"airdate":"2026-11-26"},{"ep":39,"sort":39,"airdate":""}]}"#
        let parsed = try Bangumi.parseEpisodes(Data(episodes.utf8), today: "2026-11-21")
        XCTAssertEqual(parsed.aired, 36); XCTAssertEqual(parsed.next, 37); XCTAssertEqual(parsed.nextDate, "2026-11-22")
        let info = AiringInfo(checkedAt: Date(), status: Airing.ongoing, episodes: 40, episodesAired: 35)
        let merged = Bangumi.merge(info, BangumiInfo(id: 466759, checkedAt: Date(), aired: 36, nextEpisode: 37, nextDate: "2026-11-22"))
        XCTAssertEqual(merged.episodesAired, 36); XCTAssertEqual(merged.nextEpisode, 37)
        XCTAssertEqual(Bangumi.merge(info, BangumiInfo(id: 0, checkedAt: Date())).episodesAired, 35)
        XCTAssertEqual(Bangumi.line(merged.bangumi!), "Bangumi: вышла 36 · 37-я — 22 ноября (Китай)")
    }

    func testShikimoriRefreshKeepsBangumiAndLibria() {
        var entry = Entry(title: "История"); entry.sourceID = 1
        var old = AiringInfo(checkedAt: Date(), status: Airing.ongoing)
        old.bangumi = BangumiInfo(id: 5, checkedAt: Date(), aired: 3)
        old.libria = LibriaInfo(alias: "x", publishedEpisode: 2)
        entry.airing = old
        let next = Airing.apply(entry, AiringInfo(checkedAt: Date(), status: Airing.ongoing, episodesAired: 4))
        XCTAssertEqual(next.airing?.bangumi?.id, 5); XCTAssertEqual(next.airing?.libria?.alias, "x"); XCTAssertEqual(next.airing?.episodesAired, 4)
    }

    func testMirrorPreferenceSurvivesBackupAndRejectsJunk() throws {
        var snapshot = Snapshot(); snapshot.preferences.anivibeHost = "anivibe.xyz"
        XCTAssertEqual(try Snapshot.decode(snapshot.encoded()).preferences.anivibeHost, "anivibe.xyz")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        var prefs = try XCTUnwrap(json["preferences"] as? [String: Any]); prefs["anivibeHost"] = "not a host"; json["preferences"] = prefs
        XCTAssertNil(try Snapshot.decode(JSONSerialization.data(withJSONObject: json)).preferences.anivibeHost)
    }
}
