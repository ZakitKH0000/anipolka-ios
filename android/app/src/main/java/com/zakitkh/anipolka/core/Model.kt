package com.zakitkh.anipolka.core

import java.time.Instant
import java.util.UUID

/** Same raw values as the iOS app, so collection files and backups are interchangeable. */
enum class WatchStatus(val raw: String) {
    WATCHING("Смотрю"), PLANNED("На потом"), COMPLETED("Завершено"), DROPPED("Заброшено");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

enum class Theme(val raw: String, val label: String) {
    DARK("Тёмное", "Тёмное"), LIGHT("Светлое", "Светлое"), SYSTEM("Как на iPhone", "Как в системе");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

enum class Layout(val raw: String, val label: String) {
    LIST("Компактный список", "Компактный список"), GRID("Сетка обложек", "Сетка обложек");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

enum class ShelfSort(val raw: String) {
    RECENT("По последнему просмотру"), TITLE("По названию"), MANUAL("Вручную");
    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

/** Image bytes with value equality, so entries can be compared like in Swift. */
class Blob(val bytes: ByteArray) {
    val size get() = bytes.size
    override fun equals(other: Any?) = other is Blob && other.bytes.contentEquals(bytes)
    override fun hashCode() = bytes.contentHashCode()
}

class ShelfError(message: String) : Exception(message)

data class Preferences(
    val theme: Theme = Theme.DARK,
    val layout: Layout = Layout.GRID,
    val sort: ShelfSort = ShelfSort.RECENT,
    val showContinue: Boolean = true,
    val haptics: Boolean = true,
    val wifiOnly: Boolean = false,
    val automaticCovers: Boolean = true,
    val releaseNotifications: Boolean = false,
    val backgroundChecks: Boolean = true,
    /** One local reminder on days when the user's own schedule lists releases. */
    val dailyDigest: Boolean = false,
    val digestMinutes: Int = 19 * 60,
    val appLock: Boolean = false,
    /** Grouped by status on the collection screen. */
    val shelves: Boolean = false,
    val pureBlack: Boolean = false,
    val favoriteDubs: List<String> = emptyList(),
    /** Next-episode times, aired counts and continuations from Shikimori (only catalogue IDs are sent). */
    val catalogUpdates: Boolean = true,
    /** A local notification at the announced broadcast time of the next episode. */
    val airingReminders: Boolean = false,
)

data class CoverDiscovery(val checkedAt: Instant, val query: String, val message: String, val needsChoice: Boolean) {
    constructor(query: String, message: String, needsChoice: Boolean) : this(Instant.now(), query, message, needsChoice)
}

data class ReleaseSubscription(
    val id: UUID = UUID.randomUUID(),
    val pageURL: String,
    val optionID: String,
    val label: String,
    val enabled: Boolean = true,
    val lastEpisode: Int? = null,
    val lastCheckedAt: Instant? = null,
    val error: String? = null,
) {
    companion object {
        fun create(pageURL: String, optionID: String, label: String, episode: Int, now: Instant = Instant.now()) =
            ReleaseSubscription(pageURL = pageURL, optionID = optionID, label = label, lastEpisode = episode, lastCheckedAt = now)
    }
}

data class ReleaseNotice(
    val id: String,
    val subscriptionID: UUID,
    val title: String,
    val episode: Int,
    val previousEpisode: Int,
    val url: String,
    val foundAt: Instant,
    val sourceLabel: String? = null,
    val read: Boolean = false,
) {
    companion object {
        fun create(subscription: ReleaseSubscription, entryTitle: String, episode: Int, url: String, now: Instant = Instant.now()) = ReleaseNotice(
            id = "${subscription.id.toString().uppercase()}-$episode", subscriptionID = subscription.id, title = entryTitle,
            episode = episode, previousEpisode = subscription.lastEpisode ?: episode, url = url, foundAt = now, sourceLabel = subscription.label,
        )
    }
}

/** One progress step recorded by the app. Only used for local statistics. */
data class WatchMark(val entryID: UUID, val at: Instant, val episodes: Int) {
    companion object { const val LIMIT = 20_000 }
}

/** «Где остановился» and other notes tied to an episode. */
data class EpisodeNote(
    val id: UUID = UUID.randomUUID(),
    val episode: Int,
    /** Position inside the episode, «14:30» or «1:02:03»; empty when not given. */
    val time: String = "",
    val text: String = "",
    val createdAt: Instant = Instant.now(),
) { companion object { const val LIMIT = 300 } }

/** A place where the title is watched: a platform, a playlist, a specific dub. */
data class WatchLink(val id: UUID = UUID.randomUUID(), val label: String, val url: String) {
    companion object { const val LIMIT = 20 }
}

data class Entry(
    val id: UUID = UUID.randomUUID(),
    val title: String,
    val originalTitle: String = "",
    val episode: Int = 0,
    val season: Int? = null,
    val status: WatchStatus = WatchStatus.WATCHING,
    val favorite: Boolean = false,
    val note: String = "",
    val watchURL: String = "",
    val sourceURL: String = "",
    val sourceID: Int? = null,
    val coverURL: String = "",
    val coverData: Blob? = null,
    val updatedAt: Instant = Instant.now(),
    val watchedAt: Instant? = null,
    val coverDiscovery: CoverDiscovery? = null,
    val coverLookupDisabled: Boolean? = null,
    val subscriptions: List<ReleaseSubscription> = emptyList(),
    val releaseNotices: List<ReleaseNotice> = emptyList(),
    /** Personal rating, 1...5 stars. */
    val rating: Int? = null,
    val completedAt: Instant? = null,
    /** Calendar weekdays as in iOS: 1 = Sunday ... 7 = Saturday. */
    val releaseDays: List<Int> = emptyList(),
    val tags: List<String> = emptyList(),
    /** Other names of the same work (catalogue titles, source titles, the user's variants). */
    val aliases: List<String> = emptyList(),
    val notes: List<EpisodeNote> = emptyList(),
    /** Extra places to watch; `watchURL` stays the main one. */
    val links: List<WatchLink> = emptyList(),
    /** Number of rewatches started; the first pass ended at `firstRunEpisode`. */
    val rewatch: Int? = null,
    val firstRunEpisode: Int? = null,
    val premiereDate: Instant? = null,
    /** Other seasons, films or parts of the same story in the collection. */
    val relatedIDs: List<UUID> = emptyList(),
    /** Broadcast data from Shikimori: aired episodes, next episode time, continuation. */
    val airing: AiringInfo? = null,
    /** Continuation the user chose not to add. */
    val dismissedSequelID: Int? = null,
) {
    val displayTitle get() = title + if (favorite && !title.contains("⭐") && !title.contains("★")) " ★" else ""
    val subtitle get() = (season?.let { "Сезон $it · " } ?: "") + "Последняя серия: $episode"
}

data class Snapshot(
    val format: String = "AniPolka",
    val version: Int = 1,
    val entries: List<Entry> = emptyList(),
    val preferences: Preferences = Preferences(),
    /** Episode marks made in the app; used only for local statistics. */
    val history: List<WatchMark> = emptyList(),
) {
    fun validated(): Snapshot {
        if (format != "AniPolka" || version != 1) throw ShelfError("Неподдерживаемый формат резервной копии.")
        if (entries.size > 2000 || entries.map { it.id }.toSet().size != entries.size) throw ShelfError("Слишком много записей или повторяющиеся идентификаторы.")
        for (e in entries) {
            val name = e.title.take(60)
            if (e.title.isBlank() || e.title.length > 500 || e.episode !in 0..1_000_000 || (e.season != null && e.season !in 1..10000) ||
                e.note.length > 20000 || e.watchURL.length > 4000 || e.coverURL.length > 4000 || (e.coverData?.size ?: 0) > 3_000_000
            ) throw ShelfError("Недопустимые данные записи «$name».")
            val linkOk = e.links.all { l -> l.label.isNotEmpty() && l.label.length <= 100 && l.url.length <= 4000 && (l.url.lowercase().startsWith("https://") || l.url.lowercase().startsWith("http://")) }
            if ((e.rating != null && e.rating !in 1..5) || !e.releaseDays.all { it in 1..7 } || e.releaseDays.size > 7 ||
                e.tags.size > Tags.LIMIT || !e.tags.all { it.isNotEmpty() && it.length <= Tags.MAX_LENGTH } ||
                e.aliases.size > Aliases.LIMIT || !e.aliases.all { it.isNotEmpty() && it.length <= Aliases.MAX_LENGTH } ||
                e.notes.size > EpisodeNote.LIMIT || !e.notes.all { it.episode in 0..1_000_000 && it.time.length <= 20 && it.text.length <= 2000 } ||
                e.links.size > WatchLink.LIMIT || !linkOk ||
                (e.rewatch != null && e.rewatch !in 0..1000) || (e.firstRunEpisode != null && e.firstRunEpisode !in 0..1_000_000) ||
                e.relatedIDs.size > Relations.LIMIT
            ) throw ShelfError("Недопустимая оценка, расписание или метки записи «$name».")
            e.airing?.let { a ->
                val sq = a.sequel
                if (a.status.length > 20 || (a.episodes != null && a.episodes !in 0..100_000) || (a.episodesAired != null && a.episodesAired !in 0..100_000) ||
                    (sq != null && (sq.title.length > 500 || sq.originalTitle.length > 500 || sq.coverURL.length > 4000 || sq.status.length > 20 || (sq.airedOn?.length ?: 0) > 20)))
                    throw ShelfError("Некорректные данные каталога в записи «$name».")
            }
            if (e.subscriptions.size > 20 || e.releaseNotices.size > 100) throw ShelfError("Слишком много источников или уведомлений в записи.")
            if (e.subscriptions.map { it.id }.toSet().size != e.subscriptions.size || e.releaseNotices.map { it.id }.toSet().size != e.releaseNotices.size)
                throw ShelfError("Повторяющиеся источники или уведомления.")
            for (s in e.subscriptions) {
                if (AnivibePageParser.canonicalURL(s.pageURL) == null || s.label.length > 500 || s.optionID.length > 150 || (s.lastEpisode != null && s.lastEpisode !in 0..1_000_000))
                    throw ShelfError("Некорректные данные источника серий.")
            }
            for (n in e.releaseNotices) {
                if (AnivibePageParser.canonicalURL(n.url) == null || n.episode !in 1..1_000_000 || n.previousEpisode !in 0 until n.episode || n.title.length > 500 || n.id.length > 200)
                    throw ShelfError("Некорректная ссылка новой серии.")
            }
        }
        if (history.size > WatchMark.LIMIT || !history.all { it.episodes in 1..1_000_000 }) throw ShelfError("Повреждена история просмотра.")
        return this
    }

    fun encoded(): ByteArray {
        validated()
        val data = SnapshotJson.encode(this)
        if (data.size > 150_000_000) throw ShelfError("Коллекция превысила 150 МБ. Уменьшите количество обложек перед сохранением.")
        return data
    }

    fun visible(query: String = "", status: WatchStatus? = null, favorites: Boolean = false, tag: String? = null, behindOnly: Boolean = false, dub: String? = null): List<Entry> {
        val needle = query.trim()
        val result = entries.filter { e ->
            (status == null || e.status == status) && (!favorites || e.favorite) &&
                (tag == null || Tags.contains(e.tags, tag)) && (!behindOnly || Backlog.available(e) != null) && (dub == null || Dubs.entryUses(e, dub)) &&
                (needle.isEmpty() || e.title.contains(needle, true) || e.originalTitle.contains(needle, true) || e.note.contains(needle, true) ||
                    e.tags.any { it.contains(needle, true) } || e.aliases.any { it.contains(needle, true) })
        }
        return when (preferences.sort) {
            ShelfSort.MANUAL -> result
            ShelfSort.TITLE -> result.sortedWith { a, b -> TitleIdentity.compareStandard(a.title, b.title) }
            ShelfSort.RECENT -> result.sortedWith { a, b ->
                val aw = a.watchedAt ?: Instant.MIN; val bw = b.watchedAt ?: Instant.MIN
                if (aw == bw) b.updatedAt.compareTo(a.updatedAt) else bw.compareTo(aw)
            }
        }
    }

    fun merged(backup: Snapshot): Snapshot {
        val ids = entries.map { it.id }.toSet()
        return copy(entries = entries + backup.entries.filter { it.id !in ids })
    }

    fun reordered(ids: List<UUID>): Snapshot {
        val lookup = entries.associateBy { it.id }
        if (ids.size != entries.size || ids.toSet() != lookup.keys) return this
        return copy(entries = ids.mapNotNull { lookup[it] })
    }

    fun withEntry(id: UUID, block: (Entry) -> Entry): Snapshot {
        val i = entries.indexOfFirst { it.id == id }
        if (i < 0) return this
        return copy(entries = entries.toMutableList().also { it[i] = block(it[i]) })
    }

    fun entry(id: UUID) = entries.firstOrNull { it.id == id }

    companion object {
        fun decode(data: ByteArray): Snapshot {
            if (data.size > 150_000_000) throw ShelfError("Файл больше 150 МБ.")
            return try { SnapshotJson.decode(data).validated() }
            catch (e: ShelfError) { throw e }
            catch (e: Exception) { throw ShelfError("Не удалось прочитать копию АниПолки. Текущая коллекция сохранена.") }
        }
    }
}

data class EpisodeUndo(val id: UUID, val previous: Entry, val applied: Entry)

data class ImportRow(
    val id: UUID = UUID.randomUUID(),
    val original: String,
    val title: String,
    val episode: Int,
    val favorite: Boolean,
    val recognized: Boolean,
    val included: Boolean = true,
    /** Title of an existing entry with the same name (any of its names). */
    val duplicateOf: String? = null,
) {
    val entry get() = Entry(title = title, episode = episode, favorite = favorite)
}

object TextListParser {
    private val pattern = Regex("""^(.*?)\s+(?:[—–\-:]\s*)?(\d{1,7})(?:\s*(?:серия|серии|серий|сер\.?))?$""", RegexOption.IGNORE_CASE)
    fun parse(text: String): List<ImportRow> {
        val source = text.removePrefix("﻿")
        return source.split("\r\n", "\n", "\r").mapNotNull { raw ->
            val line = raw.trim()
            if (line.isEmpty()) return@mapNotNull null
            // Only a trailing, separated number is progress. Ambiguous lines keep their full title.
            val match = pattern.find(line)
            val number = match?.groupValues?.get(2)?.toIntOrNull()
            if (match != null && number != null && number <= 1_000_000) {
                val title = match.groupValues[1].trim()
                if (title.isNotEmpty()) return@mapNotNull ImportRow(original = raw, title = title, episode = number, favorite = title.contains("⭐") || title.contains("★"), recognized = true)
            }
            ImportRow(original = raw, title = line, episode = 0, favorite = line.contains("⭐") || line.contains("★"), recognized = false)
        }
    }
}

object CoverPolicy {
    fun permits(wifiOnly: Boolean, connected: Boolean, wifi: Boolean) = connected && (!wifiOnly || wifi)
}
