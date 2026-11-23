package com.zakitkh.anipolka

import com.zakitkh.anipolka.core.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.UUID

class CoreTests {
    private val kyiv = ZoneId.of("Europe/Kiev")
    private fun date(y: Int, m: Int, d: Int, h: Int = 12) = ZonedDateTime.of(y, m, d, h, 0, 0, 0, kyiv).toInstant()

    @Test fun readsACollectionWrittenByTheIOSApp() {
        val id = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        val json = """{"format":"AniPolka","version":1,"entries":[{"id":"$id","title":"Пожиратель звёзд","originalTitle":"Tunshi Xingkong","episode":24,
            "status":"Смотрю","favorite":true,"note":"","watchURL":"","sourceURL":"","coverURL":"","coverData":"/9j/","updatedAt":783874800.5,
            "subscriptions":[{"id":"5E7A8B7C-1111-2222-3333-444455556666","pageURL":"https://anivibe.pro/anime/44218","optionID":"kodik-1-1","label":"ПВА ШОУ · Kodik","enabled":true,"lastEpisode":27}],
            "rating":4,"releaseDays":[2,7]}],"preferences":{"theme":"Тёмное","layout":"Компактный список"}}"""
        val s = Snapshot.decode(json.toByteArray())
        val e = s.entries.single()
        assertEquals(UUID.fromString(id), e.id); assertEquals(24, e.episode); assertEquals(WatchStatus.WATCHING, e.status)
        assertArrayEquals(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte()), e.coverData!!.bytes)
        assertEquals(Instant.parse("2025-11-03T15:00:00.5Z"), e.updatedAt)
        assertEquals(Layout.LIST, s.preferences.layout); assertEquals(3, Backlog.available(e))
        // Writing back keeps the iOS shape and the same values.
        val again = Snapshot.decode(s.encoded())
        assertEquals(s, again)
        assertTrue(String(s.encoded()).contains("\"id\":\"$id\""))
    }

    @Test fun rejectsBrokenBackupsAndUnsupportedVersions() {
        assertThrows(ShelfError::class.java) { Snapshot.decode("broken".toByteArray()) }
        assertThrows(ShelfError::class.java) { Snapshot(version = 2).encoded() }
        val e = Entry(title = "Повтор")
        assertThrows(ShelfError::class.java) { Snapshot(entries = listOf(e, e)).encoded() }
        assertThrows(ShelfError::class.java) { Snapshot(entries = listOf(Entry(title = " "))).encoded() }
        assertThrows(ShelfError::class.java) { Snapshot(entries = listOf(Entry(title = "x", rating = 6))).encoded() }
    }

    @Test fun repositoryIsAtomicAndUndoRestoresProgressAndHistory() {
        val dir = Files.createTempDirectory("shelf").toFile()
        val r = ShelfRepository(File(dir, "AniPolka/shelf.json"))
        val e = Entry(title = "История", episode = 24)
        r.commit(Snapshot(entries = listOf(e)))
        val token = r.increment(e.id, by = 3, now = date(2026, 11, 1))!!
        assertEquals(27, r.snapshot.entries[0].episode); assertEquals(listOf(3), r.snapshot.history.map { it.episodes })
        assertEquals(27, ShelfRepository(r.file).snapshot.entries[0].episode)
        r.undo(token)
        assertEquals(24, r.snapshot.entries[0].episode); assertTrue(r.snapshot.history.isEmpty())
        val bytes = r.file.readBytes()
        assertThrows(ShelfError::class.java) { r.commit(r.snapshot.copy(entries = listOf(e.copy(episode = -1)))) }
        assertArrayEquals(bytes, r.file.readBytes())
    }

    @Test fun textImportKeepsSpellingAndStars() {
        val rows = TextListParser.parse("Мой дракон⭐ 24\nИсходнае название\nИстория — 150 серий\n86\nДругая 2\n\n")
        assertEquals(5, rows.size)
        assertEquals("Мой дракон⭐", rows[0].title); assertEquals(24, rows[0].episode); assertTrue(rows[0].favorite)
        assertFalse(rows[1].recognized); assertEquals(150, rows[2].episode); assertEquals("86", rows[3].title)
        assertEquals("Первая", TextListParser.parse("﻿Первая 3").first().title)
    }

    @Test fun titleIdentityFoldsCaseAccentsAndPunctuation() {
        assertEquals("пожиратель звезд", TitleIdentity.normalized("Пожиратель  ЗВЁЗД!"))
        assertEquals("tunshixingkong", TitleMatcher.key("Tun Shi Xing Kong ★"))
        assertEquals(1, TitleIdentity.uniqueExactMatch("Tunshi Xingkong", listOf(listOf("Другое"), listOf("Пожиратель звёзд", "Tunshi Xingkong"))))
        assertNull(TitleIdentity.uniqueExactMatch("ab", listOf(listOf("ab"))))
    }

    @Test fun anivibePageGivesTracksNamesAndCanonicalAddress() {
        assertEquals("https://anivibe.pro/anime/44218", AnivibePageParser.canonicalURL("https://www.anivibe.pro/anime/44218?episode=27#play"))
        assertNull(AnivibePageParser.canonicalURL("http://anivibe.pro/anime/44218"))
        assertNull(AnivibePageParser.canonicalURL("https://evil.example/anime/1"))
        val html = """<meta property="og:image" content="https://anivibe.pro/c.jpg"><script>const kodikData = {"material_data":{"anime_title":"Сказание о пастухе богов","title_en":"Mu shen ji","other_titles":["Mu Shen Ji","ToHG"]},
            "translations":[{"id":1,"title":"ПВА ШОУ","last_episode":104},{"id":2,"title":"Animy","last_episode":105,"season":1}]};
            window.__vidozaData = window.__unpackVidozaGroups([{"vn":"HORIZON","tt":"voice","tl":"ru","eps":[{"e":1},{"e":104}]}]);</script>"""
        val page = AnivibePageParser.parse(html, "https://anivibe.pro/anime/59953-mushen-ji")
        assertEquals(listOf("kodik-1-0", "kodik-2-1", "anivibe-voice||ru||HORIZON"), page.options.map { it.id })
        assertEquals("Animy · сезон 1 · Kodik", page.options[1].label)
        assertEquals(listOf("Сказание о пастухе богов", "Mu shen ji", "ToHG"), page.names)
        assertEquals("https://anivibe.pro/c.jpg", page.coverURL)
        assertTrue(page.watchURL(page.options[0], 104).endsWith("?episode=104&translation=%D0%9F%D0%92%D0%90%20%D0%A8%D0%9E%D0%A3&player=kodik#player-section"))
    }

    @Test fun releaseTrackerSetsBaselineThenReportsOnlyNewEpisodes() {
        val sub = ReleaseSubscription(pageURL = "https://anivibe.pro/anime/1", optionID = "kodik-1-0", label = "ПВА ШОУ")
        val entry = Entry(title = "История", subscriptions = listOf(sub))
        fun page(n: Int) = SourcePage("t", "https://anivibe.pro/anime/1", null, listOf(SourceOption("kodik-1-0", "ПВА ШОУ · Kodik", n, 1, "ПВА ШОУ")))
        val (base, none) = ReleaseTracker.observe(page(10), entry, sub.id)
        assertNull(none); assertEquals(10, base.subscriptions[0].lastEpisode)
        val (next, notice) = ReleaseTracker.observe(page(12), base, sub.id)
        assertEquals(12, notice!!.episode); assertEquals(10, notice.previousEpisode); assertEquals(1, next.releaseNotices.size)
        assertThrows(ShelfError::class.java) { ReleaseTracker.observe(page(5), next, sub.id) }
    }

    @Test fun coverLookupSkipsPlaceholderAndKeepsShikimoriIdentity() = runBlocking {
        val missing = "https://shikimori.io/assets/globals/missing_original.jpg"
        val kitsuPoster = "https://media.kitsu.app/anime/123/poster_image/large.jpg"
        val primary = AnimeCandidate(60416, "Wu Lian Dianfeng", "Пик боевых искусств", missing, missing, "/animes/60416", "ona", 48, "2024-12-05")
        val secondary = AnimeCandidate(123, "Wu Lian Dianfeng", null, kitsuPoster, kitsuPoster, "https://kitsu.app/anime/x", "ONA", 48, "2024-12-05", AnimeCatalog.KITSU)
        val downloads = mutableListOf<String>()
        val result = AutomaticCoverLookup.resolve(Entry(title = "Пик боевых искусств"),
            search = { _, catalog -> listOf(if (catalog == AnimeCatalog.SHIKIMORI) primary else secondary) },
            lookup = { null }, download = { downloads += it; byteArrayOf(1, 2) })
        val found = (result as CoverResolution.Found).cover
        assertEquals(listOf(kitsuPoster), downloads); assertEquals(60416, found.candidate?.shikimoriID)
        assertEquals("https://shikimori.io/animes/60416", found.candidate?.pageURL)
        assertTrue(CoverImagePolicy.isPlaceholder(missing)); assertNull(CoverImagePolicy.usableURL(missing))
        // A selected ID without a confirmed name never searches by the user's own title.
        val unconfirmed = AutomaticCoverLookup.resolve(Entry(title = "Своё", sourceID = 60416),
            search = { _, _ -> fail("must not search"); emptyList() }, lookup = { throw RuntimeException("offline") }, download = { byteArrayOf(1) })
        assertEquals(CoverResolution.NotFound(false), unconfirmed)
    }

    @Test fun catalogAnswersAreDecoded() {
        val graph = """{"data":{"animes":[{"id":"44218","name":"Tunshi Xingkong","russian":"Пожиратель звёзд","english":"Swallowed Star","japanese":"吞噬星空","synonyms":["Tun Shi Xing Kong"],
            "url":"https://shikimori.io/animes/44218","kind":"ona","episodes":26,"airedOn":{"year":2020,"month":11,"day":29},"poster":{"originalUrl":"https://shikimori.io/p.jpg","mainUrl":"https://shikimori.io/m.webp"}}]}}"""
        val c = CatalogJson.shikimoriGraphQL(graph).single()
        assertEquals("Пожиратель звёзд", c.title); assertEquals("2020-11-29", c.airedOn); assertEquals("https://shikimori.io/p.jpg", c.posterURL)
        assertEquals(listOf("Swallowed Star", "吞噬星空", "Tun Shi Xing Kong"), c.aliases)
        assertThrows(ShelfError::class.java) { CatalogJson.shikimoriGraphQL("""{"data":null,"errors":[{"message":"x"}]}""") }
        val kitsu = """{"data":[{"id":"42","attributes":{"canonicalTitle":"Tunshi Xingkong","titles":{"en":"Swallowed Star","ru_ru":null},"slug":"tunshi","posterImage":{"large":"https://media.kitsu.app/l.jpg","small":"https://media.kitsu.app/s.jpg"},"subtype":"ONA","episodeCount":26,"startDate":"2020-11-29"}}]}"""
        val k = CatalogJson.kitsu(kitsu).single()
        assertNull(k.shikimoriID); assertEquals("https://media.kitsu.app/l.jpg", k.posterURL); assertEquals("https://kitsu.app/anime/tunshi", k.pageURL)
    }

    @Test fun backlogProgressAndCaughtUp() {
        fun e(own: Int, latest: Int) = Entry(title = "x", episode = own, subscriptions = listOf(ReleaseSubscription.create("https://anivibe.pro/anime/1", "a", "x", latest)))
        assertEquals(3, Backlog.available(e(24, 27))); assertNull(Backlog.available(e(24, 174)))
        assertEquals(0.5, Backlog.progress(e(12, 24))!!, 0.0001); assertNull(Backlog.progress(e(150, 105)))
        assertTrue(Backlog.caughtUp(e(26, 26))); assertFalse(Backlog.caughtUp(e(25, 26)))
    }

    @Test fun editorSaveCountsProgressAndCompletionDate() {
        val e = Entry(title = "История", episode = 10)
        var s = Snapshot(entries = listOf(e)).save(e.copy(episode = 13, status = WatchStatus.COMPLETED), date(2026, 10, 24))
        assertEquals(listOf(WatchMark(e.id, date(2026, 10, 24), 3)), s.history); assertEquals(date(2026, 10, 24), s.entries[0].completedAt)
        s = s.save(s.entries[0].copy(episode = 5, status = WatchStatus.WATCHING))
        assertEquals(1, s.history.size); assertNull(s.entries[0].completedAt)
    }

    @Test fun aliasesTagsAndDuplicates() {
        assertEquals(listOf("Swallowed Star", "吞噬星空"), Aliases.merge(listOf("Swallowed Star"), listOf("swallowed  star!", "Tun Shi Xing Kong", "Пожиратель звёзд", " 吞噬星空 "), listOf("Пожиратель звёзд", "Tunshi Xingkong")))
        assertEquals(listOf("дунхуа", "С другом", "пересмотреть"), Tags.parse(" дунхуа, С другом ,дунхуа;#пересмотреть,, "))
        val star = Entry(title = "Пожиратель звёзд", originalTitle = "Tunshi Xingkong", aliases = listOf("Swallowed Star"))
        assertEquals("Пожиратель звёзд", TitleMatcher.existing("Swallowed Star ★", listOf(star))?.title)
        assertNull(TitleMatcher.existing("Swallowed Star 2", listOf(star)))
        assertTrue(TitleMatcher.matches(listOf("Tunshi Xingkong 4th Season"), star))
        val pages = AnivibeCatalog.pages(listOf("https://anivibe.pro/anime/56524-tunshi-xingkong-4th-season", "https://anivibe.pro/anime/44218-tunshi-xingkong"))
        assertEquals(listOf(44218, 56524), AnivibeCatalog.candidates(star, pages).map { it.id })
    }

    @Test fun reportBriefTextMatchesIOS() {
        val s = Snapshot(preferences = Preferences(sort = ShelfSort.MANUAL), entries = listOf(
            Entry(title = "Пожиратель звёзд", episode = 24),
            Entry(title = "Пик боевых искусств", status = WatchStatus.PLANNED),
            Entry(title = "Сказание", episode = 104, status = WatchStatus.COMPLETED, season = 2),
            Entry(title = "Брошенная", episode = 1, status = WatchStatus.DROPPED)))
        val text = ShelfReport.text(s, ReportOptions(style = ReportOptions.Style.BRIEF, statistics = false), date(2026, 11, 6), kyiv)
        assertEquals("""Смотрю (1):
• Пожиратель звёзд — остановился на серии 24 (просмотрено: 1–24)

На потом (1):
• Пик боевых искусств — не начато

Завершено (1):
• Сказание — сезон 2, посмотрено до серии 104

Заброшено (1):
• Брошенная — остановился на серии 1 (просмотрено: серия 1)""", text)
        assertTrue(ShelfReport.text(s, ReportOptions(style = ReportOptions.Style.FOR_AI), date(2026, 11, 6), kyiv).startsWith("Это мой личный список аниме и дунхуа из приложения АниПолка на 6 ноября 2026."))
    }

    @Test fun scheduleWeekAndEpisodeTime() {
        assertEquals(7, ReleasePlanner.weekday(date(2026, 10, 24), kyiv)) // суббота
        assertEquals("«А», «Б» и «В»", ReleasePlanner.digestBody(listOf("А", "Б", "В")))
        assertEquals("Пн, Сб", ReleasePlanner.days(Entry(title = "x", releaseDays = listOf(7, 2))))
        val days = WeekPlan.days(listOf(Entry(title = "Суббота", releaseDays = listOf(7))), date(2026, 10, 24), kyiv)
        assertEquals(listOf("Суббота"), days[0].releases)
        assertEquals("4:05", EpisodeTime.normalized(" 4.05 ")); assertNull(EpisodeTime.normalized("14:75"))
        assertEquals("Пересмотр №2 · в прошлый раз: 48", Entry(title = "x", episode = 48).startRewatch().passTitle)
    }

    private fun notice(sub: UUID, episode: Int, at: Instant, read: Boolean = false) = ReleaseNotice(
        "${sub.toString().uppercase()}-$episode", sub, "Тайтл", episode, episode - 1, "https://anivibe.pro/anime/x", at, "ПВА", read)

    @Test fun watchedEpisodesMarkNoticesReadAndOldReadOnesExpire() {
        val now = date(2026, 11, 21)
        val sub = UUID.randomUUID()
        val e = Entry(title = "Тайтл", episode = 7, releaseNotices = listOf(
            notice(sub, 8, now), notice(sub, 7, now), notice(sub, 6, now.minusSeconds(40L * 86400), read = true), notice(sub, 5, now.minusSeconds(40L * 86400)),
        ))
        val tidy = NoticeInbox.tidy(e, now)
        // Episode 8 is still new; 7 is watched, so read; read 6 is older than 30 days and goes; 5 is watched and old, so it goes too.
        assertEquals(listOf(8 to false, 7 to true), tidy.releaseNotices.map { it.episode to it.read })
        val s = Snapshot(entries = listOf(tidy))
        assertEquals(1, NoticeInbox.unread(s))
        assertEquals(0, NoticeInbox.unread(NoticeInbox.markAllRead(s)))
        assertTrue(NoticeInbox.removeAll(s).entries[0].releaseNotices.isEmpty())
        assertEquals(1, NoticeInbox.removeRead(s).entries[0].releaseNotices.size)
    }

    @Test fun readsBroadcastDataAndSequelFromShikimori() {
        val json = """{"data":{"animes":[{"id":"52991","status":"released","episodes":28,"episodesAired":27,"nextEpisodeAt":null,
            "related":[{"relationKind":"sequel","anime":{"id":"59978","name":"Sousou no Frieren 2nd Season","russian":"Провожающая в последний путь Фрирен 2","status":"anons","kind":"tv","airedOn":{"date":"2026-01-16"},"poster":{"mainUrl":"https://shikimori.io/p.webp"}}},
            {"relationKind":"other","anime":{"id":"1","name":"Song","russian":"","status":"released","kind":"music"}}]},
            {"id":"21","status":"ongoing","episodes":0,"episodesAired":1180,"nextEpisodeAt":"2026-11-22T17:15:00+03:00","related":[]}]}}"""
        val now = date(2026, 11, 21)
        val found = Airing.parse(json, now)
        val frieren = found.getValue(52991)
        assertEquals(28, frieren.episodes); assertNull(frieren.nextEpisodeAt)
        assertEquals(59978, frieren.sequel?.id); assertEquals("Провожающая в последний путь Фрирен 2", frieren.sequel?.title)
        val onePiece = found.getValue(21)
        assertNull(onePiece.episodes); assertEquals(1180, onePiece.episodesAired)
        assertEquals(Instant.parse("2026-11-22T14:15:00Z"), onePiece.nextEpisodeAt)

        val watching = Airing.apply(Entry(title = "Ван-Пис", episode = 1175, sourceID = 21), onePiece, kyiv)
        assertEquals(listOf(1), watching.releaseDays) // Sunday in Kyiv
        assertEquals(1181, Airing.nextEpisode(watching, now))
        assertEquals(5, Airing.aired(watching))
        assertEquals("через 1 д 4 ч", Airing.countdown(onePiece.nextEpisodeAt!!, Instant.parse("2026-11-21T10:00:00Z")))
        val days = Airing.calendar(listOf(watching), Instant.parse("2026-11-21T10:00:00Z"), kyiv)
        assertEquals(1181, days[1].items.single().episode)
        assertTrue(days[0].items.isEmpty())

        val done = Airing.apply(Entry(title = "Фрирен", episode = 28, status = WatchStatus.COMPLETED, sourceID = 52991), frieren, kyiv)
        val hint = Airing.sequelSuggestion(done, Snapshot(entries = listOf(done)))!!
        assertNull(Airing.sequelSuggestion(done.copy(dismissedSequelID = hint.id), Snapshot(entries = listOf(done))))
        val added = Airing.sequelEntry(hint)
        assertNull(Airing.sequelSuggestion(done, Snapshot(entries = listOf(done, added))))

        // The new fields survive a backup round trip.
        val copy = Snapshot.decode(Snapshot(entries = listOf(done.copy(dismissedSequelID = 5), watching)).encoded())
        assertEquals(done.airing, copy.entries[0].airing.let { it!!.copy(checkedAt = done.airing!!.checkedAt) })
        assertEquals(5, copy.entries[0].dismissedSequelID)
        assertEquals(onePiece.nextEpisodeAt, copy.entries[1].airing?.nextEpisodeAt)
    }
}
