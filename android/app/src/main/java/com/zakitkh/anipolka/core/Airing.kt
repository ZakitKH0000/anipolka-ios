package com.zakitkh.anipolka.core

import org.json.JSONObject
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

/** Next season or other continuation found in the catalogue. */
data class SequelHint(
    val id: Int,
    val title: String,
    val originalTitle: String,
    /** Catalogue status: «anons», «ongoing» or «released». */
    val status: String,
    val coverURL: String,
    /** First air date as «yyyy-MM-dd», when known. */
    val airedOn: String? = null,
)

/** Broadcast data of a title from Shikimori: how many episodes are out and when the next one airs. */
data class AiringInfo(
    val checkedAt: Instant,
    val status: String,
    /** Planned total; null when the catalogue does not know it yet. */
    val episodes: Int? = null,
    val episodesAired: Int? = null,
    /** Original (Japanese or Chinese) broadcast time; dubs usually follow later. */
    val nextEpisodeAt: Instant? = null,
    val sequel: SequelHint? = null,
)

/** A day of the release calendar: titles with an exact time first, then the user's own release days. */
data class CalendarItem(val entry: Entry, val episode: Int?, val at: Instant?)
data class CalendarDay(val date: LocalDate, val items: List<CalendarItem>)

object Airing {
    const val ANONS = "anons"
    const val ONGOING = "ongoing"
    const val RELEASED = "released"

    private val sequelKinds = setOf("tv", "movie", "ona", "ova", "special", "tv_special")

    /** GraphQL query for several titles at once; the answer is read by [parse]. */
    fun query(ids: List<Int>): String {
        val q = "query(\$ids: String!) { animes(ids: \$ids, limit: 50) { id status episodes episodesAired nextEpisodeAt " +
            "related { relationKind anime { id name russian status kind airedOn { date } poster { mainUrl } } } } }"
        return JSONObject().put("query", q).put("variables", JSONObject().put("ids", ids.joinToString(","))).toString()
    }

    fun parse(json: String, now: Instant = Instant.now()): Map<Int, AiringInfo> {
        val list = JSONObject(json).optJSONObject("data")?.optJSONArray("animes") ?: throw ShelfError("Каталог вернул неожиданный ответ.")
        val result = HashMap<Int, AiringInfo>()
        for (i in 0 until list.length()) {
            val a = list.optJSONObject(i) ?: continue
            val id = a.optString("id").toIntOrNull() ?: continue
            val status = a.optString("status").takeIf { it in setOf(ANONS, ONGOING, RELEASED) } ?: continue
            val next = (a.opt("nextEpisodeAt") as? String)?.let { runCatching { OffsetDateTime.parse(it).toInstant() }.getOrNull() }
            var sequel: SequelHint? = null
            val related = a.optJSONArray("related")
            if (related != null) for (j in 0 until related.length()) {
                val r = related.optJSONObject(j) ?: continue
                if (r.optString("relationKind") != "sequel") continue
                val s = r.optJSONObject("anime") ?: continue
                val sid = s.optString("id").toIntOrNull() ?: continue
                if (s.optString("kind") !in sequelKinds) continue
                val name = s.optString("name")
                val russian = s.optString("russian").takeIf { it.isNotBlank() && it != "null" }
                sequel = SequelHint(
                    id = sid, title = (russian ?: name).take(500), originalTitle = name.take(500),
                    status = s.optString("status").takeIf { it in setOf(ANONS, ONGOING, RELEASED) } ?: ANONS,
                    coverURL = s.optJSONObject("poster")?.optString("mainUrl")?.takeIf { it.startsWith("https://") } ?: "",
                    airedOn = s.optJSONObject("airedOn")?.optString("date")?.takeIf { it.length == 10 },
                )
                break
            }
            result[id] = AiringInfo(
                checkedAt = now, status = status,
                episodes = a.optInt("episodes", 0).takeIf { it > 0 },
                episodesAired = a.optInt("episodesAired", 0).takeIf { it > 0 },
                nextEpisodeAt = next.takeIf { status == ONGOING || status == ANONS }, sequel = sequel,
            )
        }
        return result
    }

    /** Ongoing titles are refreshed every 6 hours (and soon after the announced time), finished ones weekly. */
    fun needsRefresh(e: Entry, now: Instant = Instant.now()): Boolean {
        if (e.sourceID == null || e.status == WatchStatus.DROPPED) return false
        val info = e.airing ?: return true
        val age = Duration.between(info.checkedAt, now)
        if (info.nextEpisodeAt != null && now.isAfter(info.nextEpisodeAt.plusSeconds(1800)) && age.toMinutes() > 30) return true
        return when (info.status) {
            ONGOING -> age.toHours() >= 6
            ANONS -> age.toHours() >= 24
            else -> age.toDays() >= 7
        }
    }

    /** Saves fresh data; empty release days are filled from the broadcast weekday. */
    fun apply(e: Entry, info: AiringInfo, zone: ZoneId = ZoneId.systemDefault()): Entry {
        var next = e.copy(airing = info)
        if (e.releaseDays.isEmpty() && info.status == ONGOING && info.nextEpisodeAt != null)
            next = next.copy(releaseDays = listOf(ReleasePlanner.weekday(info.nextEpisodeAt, zone)))
        return next
    }

    /** Number of the next episode to air, when the catalogue announces a time. */
    fun nextEpisode(e: Entry, now: Instant = Instant.now()): Int? {
        val info = e.airing ?: return null
        val at = info.nextEpisodeAt ?: return null
        if (at.isBefore(now.minusSeconds(6 * 3600))) return null
        return (info.episodesAired ?: 0) + 1
    }

    fun upcoming(e: Entry, now: Instant = Instant.now()): Instant? =
        e.airing?.nextEpisodeAt?.takeIf { it.isAfter(now.minusSeconds(6 * 3600)) && e.status != WatchStatus.DROPPED }

    /** «через 2 д 5 ч», «через 40 мин», «уже вышла». */
    fun countdown(at: Instant, now: Instant = Instant.now()): String {
        val d = Duration.between(now, at)
        if (d.isNegative || d.isZero) return "уже вышла"
        val days = d.toDays(); val hours = d.toHours() % 24; val minutes = d.toMinutes() % 60
        return "через " + when {
            days > 0 -> "$days д" + if (hours > 0) " $hours ч" else ""
            hours > 0 -> "$hours ч" + if (minutes > 0) " $minutes мин" else ""
            else -> "${maxOf(1, minutes)} мин"
        }
    }

    /** Short form for a badge on a cover: «2 д», «5 ч», «40 мин». */
    fun shortCountdown(at: Instant, now: Instant = Instant.now()): String {
        val d = Duration.between(now, at)
        if (d.isNegative || d.isZero) return "вышла"
        return when {
            d.toDays() > 0 -> "${d.toDays()} д"
            d.toHours() > 0 -> "${d.toHours()} ч"
            else -> "${maxOf(1, d.toMinutes())} мин"
        }
    }

    private val ru = Locale("ru")
    fun moment(at: Instant, zone: ZoneId = ZoneId.systemDefault(), now: Instant = Instant.now()): String {
        val date = ZonedDateTime.ofInstant(at, zone)
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
        val day = when (date.toLocalDate()) {
            today -> "сегодня"
            today.plusDays(1) -> "завтра"
            else -> DateTimeFormatter.ofPattern("EE, d MMMM", ru).format(date)
        }
        return "$day, " + DateTimeFormatter.ofPattern("HH:mm").format(date)
    }

    /** «Вышло 27 из 28 серий», «Вышло 1180 серий», «Анонс», «Завершён · 28 серий». */
    fun progressText(info: AiringInfo): String = when (info.status) {
        ANONS -> "Анонс" + (info.nextEpisodeAt?.let { " · премьера ${moment(it)}" } ?: "")
        ONGOING -> {
            val aired = info.episodesAired ?: 0
            "Выходит · вышло $aired" + (info.episodes?.let { " из $it" } ?: "") + " " + countWord(info.episodes ?: aired)
        }
        else -> "Завершён" + ((info.episodes ?: info.episodesAired)?.let { " · $it ${countWord(it)}" } ?: "")
    }

    /** Episodes already broadcast but not yet watched, by the catalogue; null when none or unknown. */
    fun aired(e: Entry): Int? {
        val info = e.airing ?: return null
        val aired = if (info.status == RELEASED) info.episodes ?: info.episodesAired else info.episodesAired
        return aired?.let { it - e.episode }?.takeIf { it in 1..9999 && e.status != WatchStatus.COMPLETED }
    }

    /** The continuation to suggest, unless it is already in the collection or was dismissed. */
    fun sequelSuggestion(e: Entry, snapshot: Snapshot): SequelHint? {
        val hint = e.airing?.sequel ?: return null
        if (e.status == WatchStatus.DROPPED || e.dismissedSequelID == hint.id) return null
        // Exact names only: the previous season's name is usually a prefix of the sequel's.
        val others = snapshot.entries.filter { it.id != e.id }
        if (others.any { it.sourceID == hint.id } || listOf(hint.title, hint.originalTitle).any { TitleMatcher.existing(it, others) != null }) return null
        return hint
    }

    fun sequelEntry(hint: SequelHint, now: Instant = Instant.now()) = Entry(
        id = UUID.randomUUID(), title = hint.title, originalTitle = hint.originalTitle, status = WatchStatus.PLANNED,
        sourceID = hint.id, sourceURL = "https://shikimori.io/animes/${hint.id}", coverURL = hint.coverURL,
        aliases = listOf(hint.originalTitle).filter { it.isNotBlank() && it != hint.title }, updatedAt = now,
        coverLookupDisabled = false,
    )

    fun sequelLabel(hint: SequelHint): String = when (hint.status) {
        ANONS -> "Анонсировано продолжение" + (hint.airedOn?.let { " · ${formatDay(it)}" } ?: "")
        ONGOING -> "Выходит продолжение"
        else -> "Вышло продолжение"
    }

    private fun formatDay(iso: String): String = runCatching {
        DateTimeFormatter.ofPattern("d MMMM yyyy", ru).format(LocalDate.parse(iso))
    }.getOrDefault(iso)

    /** Seven days from today: exact broadcast times from the catalogue, then titles on the user's release days. */
    fun calendar(entries: List<Entry>, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<CalendarDay> {
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
        val active = entries.filter { it.status == WatchStatus.WATCHING || it.status == WatchStatus.PLANNED }
        return (0L until 7L).map { offset ->
            val day = today.plusDays(offset)
            val timed = active.mapNotNull { e ->
                val at = upcoming(e, now) ?: return@mapNotNull null
                if (ZonedDateTime.ofInstant(at, zone).toLocalDate() == day) CalendarItem(e, nextEpisode(e, now), at) else null
            }.sortedBy { it.at }
            val weekday = day.dayOfWeek.value % 7 + 1
            // Titles without a known broadcast time appear on the user's own release days.
            val planned = active.filter { e -> weekday in e.releaseDays && upcoming(e, now) == null }.map { CalendarItem(it, null, null) }
            CalendarDay(day, timed + planned)
        }
    }

    private fun countWord(n: Int): String {
        val tens = n % 100; val ones = n % 10
        return if (tens in 11..14) "серий" else if (ones == 1) "серия" else if (ones in 2..4) "серии" else "серий"
    }
}

/** Keeps the new-episode inbox tidy: watched episodes are read, old read notices go away. */
object NoticeInbox {
    const val KEEP_READ_DAYS = 30L

    fun tidy(entry: Entry, now: Instant): Entry {
        if (entry.releaseNotices.isEmpty()) return entry
        val cutoff = now.minus(Duration.ofDays(KEEP_READ_DAYS))
        val notices = entry.releaseNotices
            .map { if (!it.read && it.episode <= entry.episode) it.copy(read = true) else it }
            .filter { !it.read || it.foundAt.isAfter(cutoff) }
        return if (notices == entry.releaseNotices) entry else entry.copy(releaseNotices = notices)
    }

    fun tidy(snapshot: Snapshot, now: Instant = Instant.now()): Snapshot {
        val entries = snapshot.entries.map { tidy(it, now) }
        return if (entries.indices.all { entries[it] === snapshot.entries[it] }) snapshot else snapshot.copy(entries = entries)
    }

    fun unread(snapshot: Snapshot) = snapshot.entries.sumOf { e -> e.releaseNotices.count { !it.read } }

    fun markAllRead(snapshot: Snapshot) = snapshot.copy(entries = snapshot.entries.map { e ->
        if (e.releaseNotices.none { !it.read }) e else e.copy(releaseNotices = e.releaseNotices.map { it.copy(read = true) })
    })

    fun markRead(snapshot: Snapshot, entryID: UUID, noticeID: String) = snapshot.withEntry(entryID) { e ->
        e.copy(releaseNotices = e.releaseNotices.map { if (it.id == noticeID) it.copy(read = true) else it })
    }

    fun remove(snapshot: Snapshot, entryID: UUID, noticeID: String) = snapshot.withEntry(entryID) { e ->
        e.copy(releaseNotices = e.releaseNotices.filter { it.id != noticeID })
    }

    fun removeRead(snapshot: Snapshot) = snapshot.copy(entries = snapshot.entries.map { e ->
        if (e.releaseNotices.none { it.read }) e else e.copy(releaseNotices = e.releaseNotices.filter { !it.read })
    })

    fun removeAll(snapshot: Snapshot) = snapshot.copy(entries = snapshot.entries.map { e ->
        if (e.releaseNotices.isEmpty()) e else e.copy(releaseNotices = emptyList())
    })
}
