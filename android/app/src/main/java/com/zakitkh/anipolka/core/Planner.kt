package com.zakitkh.anipolka.core

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.UUID

object Tags {
    const val LIMIT = 20
    const val MAX_LENGTH = 40
    private val separators = Regex("[,;#\n]")
    /** Comma-separated user labels; duplicates are dropped case-insensitively, order is kept. */
    fun parse(text: String): List<String> {
        val result = mutableListOf<String>()
        for (part in text.split(separators)) {
            val tag = part.trim().take(MAX_LENGTH).trim()
            if (tag.isEmpty() || result.size >= LIMIT || contains(result, tag)) continue
            result += tag
        }
        return result
    }
    /** Case- and accent-insensitive, like Swift's compare(options: [.caseInsensitive, .diacriticInsensitive]). */
    fun contains(tags: List<String>, tag: String) = tags.any { fold(it) == fold(tag) }
    private val marks = Regex("\\p{Mn}+")
    private fun fold(text: String) = java.text.Normalizer.normalize(text.lowercase(), java.text.Normalizer.Form.NFD).replace(marks, "")
    fun all(entries: List<Entry>): List<String> {
        val result = mutableListOf<String>()
        for (e in entries) for (t in e.tags) if (!contains(result, t)) result += t
        return result.sortedWith { a, b -> TitleIdentity.compareStandard(a, b) }
    }
}

object Backlog {
    /** A larger gap usually means the source numbers seasons differently from the user. */
    const val PLAUSIBLE_GAP = 99
    fun latest(entry: Entry): Int? = entry.subscriptions.filter { it.enabled }.mapNotNull { it.lastEpisode }.maxOrNull()
    /** Episodes available in connected sources beyond the user's own mark. */
    fun available(entry: Entry): Int? {
        if (entry.status != WatchStatus.WATCHING && entry.status != WatchStatus.PLANNED) return null
        val latest = latest(entry) ?: return null
        if (latest <= entry.episode || latest - entry.episode > PLAUSIBLE_GAP) return null
        return latest - entry.episode
    }
    /** Watched up to the latest episode of an enabled source; waiting for the next one. */
    fun caughtUp(entry: Entry) = entry.status == WatchStatus.WATCHING && latest(entry) == entry.episode && entry.episode > 0
    /** Share of the source's latest episode already watched; nil when the numbering does not line up. */
    fun progress(entry: Entry): Double? {
        val latest = latest(entry) ?: return null
        if (latest <= 0 || entry.episode > latest || latest - entry.episode > PLAUSIBLE_GAP) return null
        return entry.episode.toDouble() / latest
    }
}

object ReleasePlanner {
    /** Monday first, as on a Russian calendar; values are iOS weekdays (1 = Sunday). */
    val displayOrder = listOf(2, 3, 4, 5, 6, 7, 1)
    private val short = listOf("Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб")
    val fullNames = listOf("воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота")
    fun shortName(weekday: Int) = if (weekday in 1..7) short[weekday - 1] else ""
    fun days(entry: Entry) = displayOrder.filter { it in entry.releaseDays }.joinToString(", ") { shortName(it) }
    fun weekday(of: Instant, zone: ZoneId = ZoneId.systemDefault()) = weekdayOf(ZonedDateTime.ofInstant(of, zone))
    fun weekdayOf(date: ZonedDateTime) = date.dayOfWeek.value % 7 + 1
    fun due(entries: List<Entry>, weekday: Int) = entries.filter { (it.status == WatchStatus.WATCHING || it.status == WatchStatus.PLANNED) && weekday in it.releaseDays }
    fun digestBody(titles: List<String>): String {
        val shown = titles.take(4).map { "«$it»" }
        if (shown.isEmpty()) return ""
        if (titles.size > 4) return shown.joinToString(", ") + " и ещё ${titles.size - 4}"
        return if (shown.size == 1) shown[0] else shown.dropLast(1).joinToString(", ") + " и " + shown.last()
    }
    /** Titles in progress, most recently watched first. */
    fun continuing(entries: List<Entry>, limit: Int) =
        entries.filter { it.status == WatchStatus.WATCHING }.sortedByDescending { it.watchedAt ?: it.updatedAt }.take(limit)
}

data class WatchStats(
    val lastWeek: Int, val lastMonth: Int, val thisYear: Int, val trackingSince: Instant?, val totalEpisodes: Int,
    val byStatus: Map<WatchStatus, Int>, val completedThisYear: Int, val averageRating: Double?, val topRated: List<String>,
) {
    companion object {
        fun of(snapshot: Snapshot, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): WatchStats {
            val year = ZonedDateTime.ofInstant(now, zone).year
            var week = 0; var month = 0; var thisYear = 0
            for (m in snapshot.history) {
                if (m.at.isAfter(now)) continue
                val age = now.epochSecond - m.at.epochSecond
                if (age < 7 * 86400) week += m.episodes
                if (age < 30 * 86400) month += m.episodes
                if (ZonedDateTime.ofInstant(m.at, zone).year == year) thisYear += m.episodes
            }
            val ratings = snapshot.entries.mapNotNull { it.rating }
            return WatchStats(
                week, month, thisYear, snapshot.history.minOfOrNull { it.at }, snapshot.entries.sumOf { it.episode },
                snapshot.entries.groupingBy { it.status }.eachCount(),
                snapshot.entries.count { e -> e.completedAt?.let { ZonedDateTime.ofInstant(it, zone).year == year } ?: false },
                if (ratings.isEmpty()) null else ratings.sum().toDouble() / ratings.size,
                snapshot.entries.filter { it.rating == 5 }.map { it.title }.sortedWith { a, b -> TitleIdentity.compareStandard(a, b) },
            )
        }
    }
}

fun Snapshot.recordWatch(entryID: UUID, episodes: Int, at: Instant): Snapshot {
    if (episodes <= 0) return this
    val marks = (history + WatchMark(entryID, at, minOf(episodes, 1_000_000))).takeLast(WatchMark.LIMIT)
    return copy(history = marks)
}

/** Stores an edited entry; progress made in the editor counts in statistics and «Завершено» remembers the date. */
fun Snapshot.save(edited: Entry, now: Instant = Instant.now()): Snapshot {
    var entry = if (edited.status != WatchStatus.COMPLETED) edited.copy(completedAt = null) else edited
    val i = entries.indexOfFirst { it.id == entry.id }
    if (i >= 0) {
        val old = entries[i]
        if (entry.status == WatchStatus.COMPLETED && old.status != WatchStatus.COMPLETED && entry.completedAt == null) entry = entry.copy(completedAt = now)
        val base = if (entry.episode > old.episode) recordWatch(entry.id, entry.episode - old.episode, now) else this
        return base.copy(entries = base.entries.toMutableList().also { it[i] = entry })
    }
    if (entry.status == WatchStatus.COMPLETED && entry.completedAt == null) entry = entry.copy(completedAt = now)
    return copy(entries = entries + entry)
}
