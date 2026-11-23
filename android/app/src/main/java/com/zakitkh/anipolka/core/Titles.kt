package com.zakitkh.anipolka.core

import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.TemporalAdjusters
import java.util.UUID
import kotlin.random.Random

/** Other names of a work: Russian, English, original, Chinese and the user's own variants. */
object Aliases {
    const val LIMIT = 30
    const val MAX_LENGTH = 200
    /** One name per line; names may contain commas, so only line breaks separate them. */
    fun parse(text: String) = merge(emptyList(), text.split("\r\n", "\n", "\r"), emptyList())
    /** Adds new names, skipping duplicates and names equal to `except` (usually the entry's own title). */
    fun merge(current: List<String>, adding: List<String>, except: List<String>): List<String> {
        val result = mutableListOf<String>()
        val seen = except.map(TitleMatcher::key).filter { it.isNotEmpty() }.toHashSet()
        for (name in current + adding) {
            val clean = name.trim().take(MAX_LENGTH)
            val key = TitleMatcher.key(clean)
            if (key.isEmpty() || result.size >= LIMIT || !seen.add(key)) continue
            result += clean
        }
        return result
    }
}

object TitleMatcher {
    /** Case, accents, punctuation, stars and spaces are ignored: «Tun Shi Xing Kong» = «Tunshi Xingkong». */
    fun key(name: String) = TitleIdentity.normalized(TitleIdentity.query(name)).replace(" ", "")
    fun names(entry: Entry) = (listOf(entry.title, entry.originalTitle) + entry.aliases).filter { it.isNotBlank() }
    fun keys(names: List<String>) = names.map(::key).filter { it.length >= 3 }.toSet()
    /** An existing entry known under exactly this name (any of its names). */
    fun existing(title: String, entries: List<Entry>): Entry? {
        val wanted = key(title)
        if (wanted.length < 3) return null
        return entries.firstOrNull { wanted in keys(names(it)) }
    }
    /** True when a source page names the same work; season pages usually extend the base name. */
    fun matches(pageNames: List<String>, entry: Entry): Boolean {
        val own = keys(names(entry)); val other = keys(pageNames)
        if (own.any { it in other }) return true
        return own.any { a -> other.any { b -> minOf(a.length, b.length) >= 6 && (a.contains(b) || b.contains(a)) } }
    }
}

/** Finds AniVibe title pages through the site's public sitemap, without its search. */
object AnivibeCatalog {
    const val SITEMAP_INDEX = "https://anivibe.pro/sitemap.xml"
    data class Page(val id: Int, val url: String, val slugName: String)
    private val loc = Regex("<loc>(.*?)</loc>", RegexOption.DOT_MATCHES_ALL)
    fun locations(xml: String) = loc.findAll(xml).map { it.groupValues[1].trim().replace("&amp;", "&") }.toList()
    /** Only sitemap files of anivibe.pro itself are followed. */
    fun sitemapFiles(xml: String) = locations(xml).filter { l ->
        runCatching { java.net.URI(l) }.getOrNull()?.let { it.scheme == "https" && it.host == "anivibe.pro" && (it.path ?: "").endsWith(".xml") } ?: false
    }.take(20)
    fun pages(locations: List<String>) = locations.mapNotNull { l ->
        val url = AnivibePageParser.canonicalURL(l) ?: return@mapNotNull null
        val last = url.trimEnd('/').substringAfterLast('/')
        val dash = last.indexOf('-').takeIf { it > 0 } ?: return@mapNotNull null
        val id = last.substring(0, dash).toIntOrNull() ?: return@mapNotNull null
        Page(id, url, last.substring(dash + 1).replace('-', ' '))
    }
    /** Exact address matches first, then pages whose address extends a known name. */
    fun candidates(entry: Entry, pages: List<Page>, limit: Int = 8): List<Page> {
        val keys = TitleMatcher.keys(TitleMatcher.names(entry))
        val seen = HashSet<Int>(); val ranked = mutableListOf<Pair<Int, Page>>()
        for (page in pages) {
            if (!seen.add(page.id)) continue
            val slug = TitleMatcher.key(page.slugName)
            if (slug in keys) ranked += 0 to page
            else if (keys.any { it.length >= 6 && slug.startsWith(it) }) ranked += 1 to page
        }
        return ranked.sortedWith(compareBy({ it.first }, { it.second.id })).map { it.second }.take(limit)
    }
}

data class WeekBucket(val start: Instant, val episodes: Int)

object WatchHistory {
    fun marks(id: UUID, snapshot: Snapshot) = snapshot.history.filter { it.entryID == id }.sortedByDescending { it.at }
    /** Episodes per week (Monday first) for the last `weeks` weeks, oldest first. */
    fun weekly(marks: List<WatchMark>, weeks: Int, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<WeekBucket> {
        if (weeks <= 0) return emptyList()
        val current = ZonedDateTime.ofInstant(now, zone).toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY)).atStartOfDay(zone)
        return (weeks - 1 downTo 0).map { back ->
            val start = current.minusWeeks(back.toLong()); val end = start.plusWeeks(1)
            WeekBucket(start.toInstant(), marks.filter { !it.at.isBefore(start.toInstant()) && it.at.isBefore(end.toInstant()) }.sumOf { it.episodes })
        }
    }
}

object ShelfExport {
    /** Same format as the text import: «Название 24», one title per line. */
    fun text(entries: List<Entry>) = entries.joinToString("\n") { "${it.title} ${it.episode}" }
}

object WatchSuggestion {
    /** Titles worth starting now: available new episodes or «На потом». */
    fun pool(entries: List<Entry>) = entries.filter { Backlog.available(it) != null || it.status == WatchStatus.PLANNED }
    fun pick(entries: List<Entry>, excluding: UUID? = null, random: Random = Random.Default): Entry? {
        val candidates = pool(entries)
        return candidates.filter { it.id != excluding }.randomOrNull(random) ?: candidates.randomOrNull(random)
    }
}

object Greeting {
    fun text(at: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()) = when (ZonedDateTime.ofInstant(at, zone).hour) {
        in 5..11 -> "Доброе утро"
        in 12..17 -> "Добрый день"
        in 18..22 -> "Добрый вечер"
        else -> "Доброй ночи"
    }
}

/** Remembers other names of the same work without touching the user's own title. */
fun Entry.learnNames(names: List<String>) = copy(aliases = Aliases.merge(aliases, names, listOf(title, originalTitle)))

/**
 * Connects a source track: remembers the page's other names, offers the page as the watch link and,
 * when there is no cover yet, the page's picture. Works on drafts in the «add» wizard too.
 */
fun Entry.attachSource(page: SourcePage, option: SourceOption, now: Instant = Instant.now()): Entry? {
    if (subscriptions.size >= 20 || subscriptions.any { it.pageURL == page.url && it.optionID == option.id }) return null
    var next = copy(subscriptions = subscriptions + ReleaseSubscription.create(page.url, option.id, option.label, option.episode, now)).learnNames(page.names)
    if (next.watchURL.isEmpty()) next = next.copy(watchURL = page.watchURL(option, option.episode))
    val cover = page.coverURL
    if (next.coverData == null && next.coverURL.isEmpty() && next.coverLookupDisabled != true && cover != null) next = next.copy(coverURL = cover, coverLookupDisabled = false)
    return next
}
