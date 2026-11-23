package com.zakitkh.anipolka.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * JSON in exactly the shape the iOS app writes with Swift's JSONEncoder:
 * dates are seconds since 1 January 2001, bytes are Base64, UUIDs are upper-case,
 * absent optional values are left out. A backup from either app opens in the other.
 */
object SnapshotJson {
    private const val REFERENCE_EPOCH = 978_307_200L

    fun date(value: Instant): Double = (value.epochSecond - REFERENCE_EPOCH) + value.nano / 1_000_000_000.0
    fun date(value: Double): Instant {
        val whole = Math.floor(value)
        val nanos = Math.round((value - whole) * 1_000_000_000.0).coerceIn(0, 999_999_999)
        return Instant.ofEpochSecond(whole.toLong() + REFERENCE_EPOCH, nanos)
    }
    private fun id(value: UUID) = value.toString().uppercase()

    fun encode(snapshot: Snapshot): ByteArray = toJson(snapshot).toString().toByteArray(Charsets.UTF_8)
    fun decode(data: ByteArray): Snapshot = fromJson(JSONObject(String(data, Charsets.UTF_8).removePrefix("﻿")))

    fun toJson(s: Snapshot): JSONObject = JSONObject().apply {
        put("format", s.format); put("version", s.version)
        put("entries", JSONArray().apply { s.entries.forEach { put(entry(it)) } })
        put("preferences", preferences(s.preferences))
        if (s.history.isNotEmpty()) put("history", JSONArray().apply {
            s.history.forEach { put(JSONObject().put("entryID", id(it.entryID)).put("at", date(it.at)).put("episodes", it.episodes)) }
        })
    }

    private fun preferences(p: Preferences) = JSONObject().apply {
        put("theme", p.theme.raw); put("layout", p.layout.raw); put("sort", p.sort.raw)
        put("showContinue", p.showContinue); put("haptics", p.haptics); put("wifiOnly", p.wifiOnly)
        put("automaticCovers", p.automaticCovers); put("releaseNotifications", p.releaseNotifications); put("backgroundChecks", p.backgroundChecks)
        put("dailyDigest", p.dailyDigest); put("digestMinutes", p.digestMinutes); put("appLock", p.appLock)
        put("shelves", p.shelves); put("pureBlack", p.pureBlack)
        put("favoriteDubs", JSONArray(p.favoriteDubs))
        put("catalogUpdates", p.catalogUpdates); put("airingReminders", p.airingReminders)
    }

    private fun entry(e: Entry) = JSONObject().apply {
        put("id", id(e.id)); put("title", e.title); put("originalTitle", e.originalTitle); put("episode", e.episode)
        e.season?.let { put("season", it) }
        put("status", e.status.raw); put("favorite", e.favorite); put("note", e.note); put("watchURL", e.watchURL)
        put("sourceURL", e.sourceURL); e.sourceID?.let { put("sourceID", it) }
        put("coverURL", e.coverURL); e.coverData?.let { put("coverData", Base64.getEncoder().encodeToString(it.bytes)) }
        put("updatedAt", date(e.updatedAt)); e.watchedAt?.let { put("watchedAt", date(it)) }
        e.coverDiscovery?.let { put("coverDiscovery", JSONObject().put("checkedAt", date(it.checkedAt)).put("query", it.query).put("message", it.message).put("needsChoice", it.needsChoice)) }
        e.coverLookupDisabled?.let { put("coverLookupDisabled", it) }
        if (e.subscriptions.isNotEmpty()) put("subscriptions", JSONArray().apply { e.subscriptions.forEach { put(subscription(it)) } })
        if (e.releaseNotices.isNotEmpty()) put("releaseNotices", JSONArray().apply { e.releaseNotices.forEach { put(notice(it)) } })
        e.rating?.let { put("rating", it) }
        e.completedAt?.let { put("completedAt", date(it)) }
        if (e.releaseDays.isNotEmpty()) put("releaseDays", JSONArray(e.releaseDays))
        if (e.tags.isNotEmpty()) put("tags", JSONArray(e.tags))
        if (e.aliases.isNotEmpty()) put("aliases", JSONArray(e.aliases))
        if (e.notes.isNotEmpty()) put("notes", JSONArray().apply {
            e.notes.forEach { put(JSONObject().put("id", id(it.id)).put("episode", it.episode).put("time", it.time).put("text", it.text).put("createdAt", date(it.createdAt))) }
        })
        if (e.links.isNotEmpty()) put("links", JSONArray().apply { e.links.forEach { put(JSONObject().put("id", id(it.id)).put("label", it.label).put("url", it.url)) } })
        e.rewatch?.let { put("rewatch", it) }
        e.firstRunEpisode?.let { put("firstRunEpisode", it) }
        e.premiereDate?.let { put("premiereDate", date(it)) }
        if (e.relatedIDs.isNotEmpty()) put("relatedIDs", JSONArray(e.relatedIDs.map { id(it) }))
        e.airing?.let { put("airing", airing(it)) }
        e.dismissedSequelID?.let { put("dismissedSequelID", it) }
    }

    private fun airing(a: AiringInfo) = JSONObject().apply {
        put("checkedAt", date(a.checkedAt)); put("status", a.status)
        a.episodes?.let { put("episodes", it) }; a.episodesAired?.let { put("episodesAired", it) }
        a.nextEpisodeAt?.let { put("nextEpisodeAt", date(it)) }
        a.sequel?.let { s ->
            put("sequel", JSONObject().apply {
                put("id", s.id); put("title", s.title); put("originalTitle", s.originalTitle); put("status", s.status); put("coverURL", s.coverURL)
                s.airedOn?.let { put("airedOn", it) }
            })
        }
    }

    private fun airing(o: JSONObject) = AiringInfo(
        checkedAt = o.requiredDate("checkedAt"), status = o.getString("status"), episodes = o.optIntOrNull("episodes"),
        episodesAired = o.optIntOrNull("episodesAired"), nextEpisodeAt = o.optDateOrNull("nextEpisodeAt"),
        sequel = (o.opt("sequel") as? JSONObject)?.let { s ->
            SequelHint(s.getInt("id"), s.getString("title"), s.getString("originalTitle"), s.getString("status"), s.getString("coverURL"), s.opt("airedOn") as? String)
        },
    )

    private fun subscription(s: ReleaseSubscription) = JSONObject().apply {
        put("id", id(s.id)); put("pageURL", s.pageURL); put("optionID", s.optionID); put("label", s.label); put("enabled", s.enabled)
        s.lastEpisode?.let { put("lastEpisode", it) }; s.lastCheckedAt?.let { put("lastCheckedAt", date(it)) }; s.error?.let { put("error", it) }
    }

    private fun notice(n: ReleaseNotice) = JSONObject().apply {
        put("id", n.id); put("subscriptionID", id(n.subscriptionID)); put("title", n.title); put("episode", n.episode)
        put("previousEpisode", n.previousEpisode); put("url", n.url); put("foundAt", date(n.foundAt)); n.sourceLabel?.let { put("sourceLabel", it) }; put("read", n.read)
    }

    // Decoding: required keys throw (like Swift), optional keys may be missing or null.

    private fun JSONObject.optIntOrNull(key: String): Int? = (opt(key) as? Number)?.let { n -> if (n.toDouble() % 1.0 != 0.0) throw ShelfError("Неверное число") else n.toInt() }
    private fun JSONObject.optDateOrNull(key: String): Instant? = (opt(key) as? Number)?.let { date(it.toDouble()) }
    private fun JSONObject.optStrings(key: String): List<String> = (opt(key) as? JSONArray)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
    private fun JSONObject.objects(key: String): List<JSONObject> = (opt(key) as? JSONArray)?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()
    private fun JSONObject.uuid(key: String): UUID = UUID.fromString(getString(key))
    private fun JSONObject.requiredDate(key: String): Instant = date(getDouble(key))

    fun fromJson(o: JSONObject): Snapshot = Snapshot(
        format = o.getString("format"), version = o.getInt("version"),
        entries = o.getJSONArray("entries").let { a -> (0 until a.length()).map { entry(a.getJSONObject(it)) } },
        preferences = preferences(o.getJSONObject("preferences")),
        history = o.objects("history").map { WatchMark(it.uuid("entryID"), it.requiredDate("at"), it.getInt("episodes")) },
    )

    private fun preferences(o: JSONObject): Preferences {
        val d = Preferences()
        fun bool(key: String, fallback: Boolean) = (o.opt(key) as? Boolean) ?: fallback
        // Unknown enum values throw in Swift too; here they fall back to safe defaults only when missing.
        fun <T> enumValue(key: String, parse: (String?) -> T?, fallback: T): T {
            val raw = o.opt(key) as? String ?: return fallback
            return parse(raw) ?: throw ShelfError("Неизвестное значение настройки $key")
        }
        return Preferences(
            theme = enumValue("theme", Theme::of, d.theme), layout = enumValue("layout", Layout::of, d.layout), sort = enumValue("sort", ShelfSort::of, d.sort),
            showContinue = bool("showContinue", d.showContinue), haptics = bool("haptics", d.haptics), wifiOnly = bool("wifiOnly", d.wifiOnly),
            automaticCovers = bool("automaticCovers", d.automaticCovers), releaseNotifications = bool("releaseNotifications", d.releaseNotifications),
            backgroundChecks = bool("backgroundChecks", d.backgroundChecks), dailyDigest = bool("dailyDigest", d.dailyDigest),
            digestMinutes = (o.optIntOrNull("digestMinutes") ?: d.digestMinutes).coerceIn(0, 1439), appLock = bool("appLock", d.appLock),
            shelves = bool("shelves", d.shelves), pureBlack = bool("pureBlack", d.pureBlack),
            favoriteDubs = o.optStrings("favoriteDubs").filter { it.isNotEmpty() && it.length <= 80 }.take(Dubs.LIMIT),
            catalogUpdates = bool("catalogUpdates", d.catalogUpdates), airingReminders = bool("airingReminders", d.airingReminders),
        )
    }

    private fun entry(o: JSONObject) = Entry(
        id = o.uuid("id"), title = o.getString("title"), originalTitle = o.getString("originalTitle"), episode = o.getInt("episode"),
        season = o.optIntOrNull("season"), status = WatchStatus.of(o.getString("status")) ?: throw ShelfError("Неизвестный статус"),
        favorite = o.getBoolean("favorite"), note = o.getString("note"), watchURL = o.getString("watchURL"), sourceURL = o.getString("sourceURL"),
        sourceID = o.optIntOrNull("sourceID"), coverURL = o.getString("coverURL"),
        coverData = (o.opt("coverData") as? String)?.let { Blob(Base64.getMimeDecoder().decode(it)) },
        updatedAt = o.requiredDate("updatedAt"), watchedAt = o.optDateOrNull("watchedAt"),
        coverDiscovery = (o.opt("coverDiscovery") as? JSONObject)?.let { CoverDiscovery(it.requiredDate("checkedAt"), it.getString("query"), it.getString("message"), it.getBoolean("needsChoice")) },
        coverLookupDisabled = o.opt("coverLookupDisabled") as? Boolean,
        subscriptions = o.objects("subscriptions").map {
            ReleaseSubscription(it.uuid("id"), it.getString("pageURL"), it.getString("optionID"), it.getString("label"), it.getBoolean("enabled"),
                it.optIntOrNull("lastEpisode"), it.optDateOrNull("lastCheckedAt"), it.opt("error") as? String)
        },
        releaseNotices = o.objects("releaseNotices").map {
            ReleaseNotice(it.getString("id"), it.uuid("subscriptionID"), it.getString("title"), it.getInt("episode"), it.getInt("previousEpisode"),
                it.getString("url"), it.requiredDate("foundAt"), it.opt("sourceLabel") as? String, it.getBoolean("read"))
        },
        rating = o.optIntOrNull("rating"), completedAt = o.optDateOrNull("completedAt"),
        releaseDays = (o.opt("releaseDays") as? JSONArray)?.let { a -> (0 until a.length()).map { a.getInt(it) } } ?: emptyList(),
        tags = o.optStrings("tags"), aliases = o.optStrings("aliases"),
        notes = o.objects("notes").map { EpisodeNote(it.uuid("id"), it.getInt("episode"), it.getString("time"), it.getString("text"), it.requiredDate("createdAt")) },
        links = o.objects("links").map { WatchLink(it.uuid("id"), it.getString("label"), it.getString("url")) },
        rewatch = o.optIntOrNull("rewatch"), firstRunEpisode = o.optIntOrNull("firstRunEpisode"), premiereDate = o.optDateOrNull("premiereDate"),
        relatedIDs = o.optStrings("relatedIDs").map { UUID.fromString(it) },
        airing = (o.opt("airing") as? JSONObject)?.let { airing(it) },
        dismissedSequelID = o.optIntOrNull("dismissedSequelID"),
    )
}
