package com.zakitkh.anipolka.core

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID

object EpisodeTime {
    /** Accepts «14:30», «14.30», «1:02:03»; returns «14:30» / «1:02:03», null for anything else. */
    fun normalized(text: String): String? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return ""
        val parts = trimmed.split(':', '.').map { it.toIntOrNull() }
        if (parts.size !in 2..3 || parts.any { it == null || it < 0 }) return null
        val v = parts.map { it!! }
        if (v.drop(1).any { it >= 60 } || v[0] >= (if (v.size == 3) 24 else 600)) return null
        return if (v.size == 2) "%d:%02d".format(v[0], v[1]) else "%d:%02d:%02d".format(v[0], v[1], v[2])
    }
}

/** The latest note: where the user stopped last time. */
val Entry.resumePoint: EpisodeNote? get() = notes.maxByOrNull { it.createdAt }

fun Entry.addNote(note: EpisodeNote) = copy(notes = (notes + note).takeLast(EpisodeNote.LIMIT))

/** Starts watching again from the beginning; the first pass stays recorded. */
fun Entry.startRewatch(now: Instant = Instant.now()) = copy(
    firstRunEpisode = maxOf(firstRunEpisode ?: 0, episode), rewatch = (rewatch ?: 0) + 1,
    episode = 0, status = WatchStatus.WATCHING, watchedAt = now, updatedAt = now,
)

/** Makes a saved link the main «Открыть просмотр» link; the previous main link stays in the list. */
fun Entry.promoteLink(id: UUID): Entry {
    val all = links.toMutableList()
    val i = all.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: return this
    val chosen = all.removeAt(i)
    if (watchURL.isNotEmpty() && all.none { it.url == watchURL }) all.add(0, WatchLink(label = "Прежняя основная", url = watchURL))
    return copy(watchURL = chosen.url, links = all)
}

val Entry.passTitle: String? get() {
    val r = rewatch ?: return null
    if (r <= 0) return null
    return "Пересмотр №${r + 1}" + (firstRunEpisode?.let { " · в прошлый раз: $it" } ?: "")
}

object PremierePlanner {
    const val REMINDER_HOUR = 10
    fun upcoming(entries: List<Entry>, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<Entry> {
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
        return entries.filter { e ->
            val date = e.premiereDate ?: return@filter false
            (e.status == WatchStatus.PLANNED || e.status == WatchStatus.WATCHING) && !ZonedDateTime.ofInstant(date, zone).toLocalDate().isBefore(today)
        }.sortedBy { it.premiereDate }
    }
    fun label(date: Instant, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val days = ChronoUnit.DAYS.between(ZonedDateTime.ofInstant(now, zone).toLocalDate(), ZonedDateTime.ofInstant(date, zone).toLocalDate())
        return when (days) {
            0L -> "Премьера сегодня"
            1L -> "Премьера завтра"
            else -> "Премьера " + DateTimeFormatter.ofPattern("d MMM", Locale("ru")).format(ZonedDateTime.ofInstant(date, zone))
        }
    }
}

data class ShelfSection(val title: String, val entries: List<Entry>)

object ShelfSections {
    /** Every title appears once, in the first group that fits it. */
    fun make(entries: List<Entry>, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<ShelfSection> {
        val used = HashSet<UUID>()
        fun take(title: String, list: List<Entry>) = list.filter { used.add(it.id) }.takeIf { it.isNotEmpty() }?.let { ShelfSection(title, it) }
        return listOfNotNull(
            take("Есть новые серии", entries.filter { Backlog.available(it) != null }),
            take("Смотрю", entries.filter { it.status == WatchStatus.WATCHING }),
            take("Скоро премьера", PremierePlanner.upcoming(entries, now, zone)),
            take("На потом", entries.filter { it.status == WatchStatus.PLANNED }),
            take("Завершено", entries.filter { it.status == WatchStatus.COMPLETED }),
            take("Заброшено", entries.filter { it.status == WatchStatus.DROPPED }),
        )
    }
}

/** Numbers for the shareable «АниПолка <год>» card. */
data class YearSummary(val year: Int, val episodes: Int, val activeDays: Int, val mostWatched: String?, val completed: List<String>, val topRated: List<String>) {
    companion object {
        fun of(snapshot: Snapshot, year: Int, zone: ZoneId = ZoneId.systemDefault()): YearSummary {
            val marks = snapshot.history.filter { ZonedDateTime.ofInstant(it.at, zone).year == year }
            val perEntry = marks.groupBy { it.entryID }.mapValues { (_, v) -> v.sumOf { it.episodes } }
            val best = perEntry.maxWithOrNull(compareBy<Map.Entry<UUID, Int>> { it.value }.thenByDescending { it.key.toString() })
            return YearSummary(
                year, marks.sumOf { it.episodes }, marks.map { ZonedDateTime.ofInstant(it.at, zone).toLocalDate() }.toSet().size,
                best?.let { b -> snapshot.entry(b.key)?.title },
                snapshot.entries.filter { e -> e.completedAt?.let { ZonedDateTime.ofInstant(it, zone).year == year } ?: false }.map { it.title },
                snapshot.entries.filter { it.rating == 5 }.map { it.title },
            )
        }
    }
}

/** The user's favourite dubbing teams, matched against connected source labels. */
object Dubs {
    const val LIMIT = 50
    /** «ПВА ШОУ · сезон 1 · Kodik» → «ПВА ШОУ». */
    fun name(label: String) = label.split(" · ").first().trim()
    fun isFavorite(name: String, favorites: List<String>) = Tags.contains(favorites, name)
    /** Favourite dubs first; the page order is kept otherwise. */
    fun sorted(options: List<SourceOption>, favorites: List<String>) = options.sortedBy { if (isFavorite(name(it.label), favorites)) 0 else 1 }
    fun entryUses(entry: Entry, dub: String) = entry.subscriptions.any { Tags.contains(listOf(name(it.label)), dub) }
    fun inUse(entries: List<Entry>, favorites: List<String>) = favorites.filter { d -> entries.any { entryUses(it, d) } }
    fun toggled(name: String, favorites: List<String>) =
        if (isFavorite(name, favorites)) favorites.filter { !Tags.contains(listOf(it), name) } else (favorites + name.take(80)).take(LIMIT)
}

data class WeekDayPlan(val date: java.time.LocalDate, val releases: List<String>, val premieres: List<String>)

object WeekPlan {
    /** Seven days starting today: titles from the user's release days and premieres on that date. */
    fun days(entries: List<Entry>, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): List<WeekDayPlan> {
        val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
        val premieres = PremierePlanner.upcoming(entries, now, zone)
        return (0L until 7L).map { offset ->
            val day = today.plusDays(offset)
            val weekday = day.dayOfWeek.value % 7 + 1
            WeekDayPlan(day, ReleasePlanner.due(entries, weekday).map { it.title },
                premieres.filter { ZonedDateTime.ofInstant(it.premiereDate!!, zone).toLocalDate() == day }.map { it.title })
        }
    }
}

object Relations {
    const val LIMIT = 30
    /** Links work both ways: a title shows parts it links to and parts that link to it. */
    fun related(entry: Entry, entries: List<Entry>) = entries.filter { it.id != entry.id && (it.id in entry.relatedIDs || entry.id in it.relatedIDs) }
    /** Removes a link in both directions. */
    fun unlink(a: UUID, b: UUID, snapshot: Snapshot) = snapshot.copy(entries = snapshot.entries.map { e ->
        when (e.id) { a -> e.copy(relatedIDs = e.relatedIDs - b); b -> e.copy(relatedIDs = e.relatedIDs - a); else -> e }
    })
}
