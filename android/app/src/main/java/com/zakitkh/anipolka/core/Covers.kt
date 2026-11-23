package com.zakitkh.anipolka.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

enum class AnimeCatalog(val label: String) { SHIKIMORI("Shikimori"), KITSU("Kitsu") }

object CoverImagePolicy {
    fun isPlaceholder(address: String): Boolean {
        val path = runCatching { URI(address).path }.getOrNull()?.lowercase() ?: return false
        // Shikimori returns HTTP 200 and a decodable JPEG for these error pictures.
        return path.contains("/assets/globals/missing_") || path == "/assets/globals/missing.jpg"
    }
    fun usableURL(address: String): String? {
        if (address.isBlank()) return null
        val uri = runCatching { URI(address.trim()) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() != "https" || uri.host == null || isPlaceholder(address)) return null
        return uri.toString()
    }
    fun acceptsResponse(status: Int, mimeType: String?, url: String) =
        status == 200 && mimeType?.lowercase()?.startsWith("image/") == true && usableURL(url) != null
}

data class AnimeCandidate(
    val id: Int,
    val name: String,
    val russian: String?,
    val imageOriginal: String,
    val imagePreview: String,
    val url: String,
    val kind: String?,
    val episodes: Int?,
    val airedOn: String?,
    val catalog: AnimeCatalog? = null,
    val aliases: List<String> = emptyList(),
) {
    val shikimoriID: Int? get() = if (catalog == AnimeCatalog.KITSU) null else id
    val title: String get() = russian?.takeIf { it.isNotEmpty() } ?: name
    val posterURL: String get() = CoverImagePolicy.usableURL(absolute(imageOriginal)) ?: ""
    val previewURL: String get() = CoverImagePolicy.usableURL(absolute(imagePreview)) ?: posterURL
    val pageURL: String get() = absolute(url)
    val names: List<String> get() = listOf(title, name) + aliases
    val detail: String get() = listOfNotNull(name, airedOn?.take(4), kind?.uppercase(), episodes?.takeIf { it > 0 }?.let { "$it серий в каталоге" }).joinToString(" · ")

    fun absolute(path: String): String {
        if (path.isBlank()) return ""
        return runCatching { URI("https://shikimori.io/").resolve(path.trim()).toString() }.getOrDefault("")
    }

    fun sameEdition(other: AnimeCandidate): Boolean {
        val own = names.map(TitleIdentity::normalized).filter { it.isNotEmpty() }.toSet()
        if (own.intersect(other.names.map(TitleIdentity::normalized).filter { it.isNotEmpty() }.toSet()).isEmpty()) return false
        val date = other.airedOn
        if (!date.isNullOrEmpty()) { if (airedOn == null || airedOn.take(4) != date.take(4)) return false }
        if (kind != null && other.kind != null && !kind.equals(other.kind, ignoreCase = true)) return false
        return true
    }
}

/** Decoding of catalogue answers; kept here so it is covered by unit tests without network. */
object CatalogJson {
    private fun JSONObject.str(key: String): String? = (opt(key) as? String)
    private fun JSONObject.int(key: String): Int? = (opt(key) as? Number)?.toInt()

    fun shikimoriGraphQL(text: String): List<AnimeCandidate> {
        val root = JSONObject(text)
        val errors = root.optJSONArray("errors")
        val data = root.optJSONObject("data")
        if ((errors != null && errors.length() > 0) || data == null) throw ShelfError("Каталог временно не вернул обложки.")
        val animes = data.optJSONArray("animes") ?: JSONArray()
        return (0 until animes.length()).mapNotNull { i ->
            val a = animes.optJSONObject(i) ?: return@mapNotNull null
            val id = a.str("id")?.toIntOrNull() ?: (a.opt("id") as? Number)?.toInt() ?: return@mapNotNull null
            val poster = a.optJSONObject("poster")
            val originalUrl = poster?.str("originalUrl"); val mainUrl = poster?.str("mainUrl")
            val original = listOfNotNull(originalUrl, mainUrl).firstOrNull { CoverImagePolicy.usableURL(it) != null } ?: ""
            val aired = a.optJSONObject("airedOn")
            val date = aired?.int("year")?.let { y -> "%04d-%02d-%02d".format(y, aired.int("month") ?: 1, aired.int("day") ?: 1) }
            val synonyms = a.optJSONArray("synonyms")?.let { s -> (0 until s.length()).mapNotNull { s.opt(it) as? String } } ?: emptyList()
            val other = (listOfNotNull(a.str("english"), a.str("japanese")) + synonyms).filter { it.isNotEmpty() }
            AnimeCandidate(id, a.getString("name"), a.str("russian"), original, mainUrl ?: original, a.optString("url"), a.str("kind"), a.int("episodes"), date, aliases = other)
        }
    }

    fun shikimoriREST(text: String): List<AnimeCandidate> {
        val array = JSONArray(text)
        return (0 until array.length()).mapNotNull { rest(array.optJSONObject(it)) }
    }
    fun shikimoriRESTOne(text: String): AnimeCandidate? = rest(JSONObject(text))
    private fun rest(a: JSONObject?): AnimeCandidate? {
        a ?: return null
        val id = a.int("id") ?: return null
        val image = a.optJSONObject("image")
        return AnimeCandidate(id, a.optString("name"), a.str("russian"), image?.str("original") ?: "", image?.str("preview") ?: "",
            a.optString("url"), a.str("kind"), a.int("episodes"), a.str("aired_on"))
    }

    fun kitsu(text: String): List<AnimeCandidate> {
        val items = JSONObject(text).optJSONArray("data") ?: JSONArray()
        return (0 until items.length()).mapNotNull { i ->
            val item = items.optJSONObject(i) ?: return@mapNotNull null
            val id = item.str("id")?.toIntOrNull() ?: return@mapNotNull null
            val a = item.optJSONObject("attributes") ?: return@mapNotNull null
            val p = a.optJSONObject("posterImage")
            val poster = listOfNotNull(p?.str("large"), p?.str("original"), p?.str("small")).firstOrNull { CoverImagePolicy.usableURL(it) != null } ?: ""
            val titles = a.optJSONObject("titles")
            val titleValues = titles?.keys()?.asSequence()?.mapNotNull { titles.opt(it) as? String }?.toList() ?: emptyList()
            val russian = titles?.str("ru_ru") ?: titles?.str("ru")
            AnimeCandidate(id, a.optString("canonicalTitle"), russian, poster, p?.str("small") ?: poster, "https://kitsu.app/anime/${a.optString("slug")}",
                a.str("subtype"), a.int("episodeCount"), a.str("startDate"), AnimeCatalog.KITSU, titleValues)
        }
    }
}

data class ResolvedCover(val candidate: AnimeCandidate?, val url: String, val data: ByteArray, val imageCatalog: AnimeCatalog?)

sealed interface CoverResolution {
    data class Found(val cover: ResolvedCover) : CoverResolution
    data class NotFound(val needsChoice: Boolean) : CoverResolution
}

/** Dependencies are injected so failures, cancellation and cross-catalog identity can be tested offline. */
object AutomaticCoverLookup {
    suspend fun resolve(
        entry: Entry,
        search: suspend (String, AnimeCatalog) -> List<AnimeCandidate>,
        lookup: suspend (Int) -> AnimeCandidate?,
        download: suspend (String) -> ByteArray,
    ): CoverResolution {
        val attempted = HashSet<String>()
        suspend fun image(address: String): ByteArray? {
            currentCoroutineContext().ensureActive()
            if (CoverImagePolicy.usableURL(address) == null || !attempted.add(address)) return null
            return try {
                download(address).takeIf { it.isNotEmpty() }.also { currentCoroutineContext().ensureActive() }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { null }
        }
        image(entry.coverURL)?.let { return CoverResolution.Found(ResolvedCover(null, entry.coverURL, it, null)) }
        var identity: AnimeCandidate? = null
        var choices = false
        val query = TitleIdentity.query(entry.originalTitle.ifEmpty { entry.title })
        val id = entry.sourceID
        if (id != null) {
            // Keep the selected catalogue ID even when only its image comes from Kitsu.
            if (entry.originalTitle.isNotEmpty()) identity = AnimeCandidate(id, entry.originalTitle, null, "", "", entry.sourceURL, null, null, null)
            try { lookup(id)?.takeIf { it.shikimoriID == id }?.let { identity = it } } catch (e: CancellationException) { throw e } catch (_: Exception) {}
            // Without a confirmed name a fallback search by the user's own title could pick another work.
            if (identity == null) { currentCoroutineContext().ensureActive(); return CoverResolution.NotFound(false) }
        } else {
            try {
                val candidates = search(query, AnimeCatalog.SHIKIMORI)
                choices = candidates.isNotEmpty()
                TitleIdentity.uniqueExactMatch(query, candidates.map { it.names })?.let { identity = candidates[it] }
            } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        }
        identity?.let { known -> image(known.posterURL)?.let { return CoverResolution.Found(ResolvedCover(known, known.posterURL, it, AnimeCatalog.SHIKIMORI)) } }
        // A found title is not proof that its poster exists.
        val fallbackQuery = identity?.name ?: query
        try {
            val candidates = search(fallbackQuery, AnimeCatalog.KITSU)
            choices = choices || candidates.isNotEmpty()
            val matching = candidates.filter { c -> identity?.let { c.sameEdition(it) } ?: true }
            TitleIdentity.uniqueExactMatch(fallbackQuery, matching.map { it.names })?.let { index ->
                val candidate = matching[index]
                image(candidate.posterURL)?.let { return CoverResolution.Found(ResolvedCover(identity ?: candidate, candidate.posterURL, it, AnimeCatalog.KITSU)) }
            }
        } catch (e: CancellationException) { throw e } catch (_: Exception) {}
        currentCoroutineContext().ensureActive()
        return CoverResolution.NotFound(identity == null && choices)
    }
}

object CoverRepair {
    /** Applies a found cover only if the entry was not changed by the user in the meantime. */
    fun apply(snapshot: Snapshot, cover: ResolvedCover, expected: Entry): Snapshot? {
        if (CoverImagePolicy.usableURL(cover.url) == null || cover.data.isEmpty() || cover.data.size > 3_000_000) return null
        val current = snapshot.entry(expected.id) ?: return null
        if (current.title != expected.title || current.coverURL != expected.coverURL || current.coverData != expected.coverData ||
            current.sourceID != expected.sourceID || current.originalTitle != expected.originalTitle || current.coverLookupDisabled == true) return null
        return snapshot.withEntry(expected.id) { e ->
            var next = e.copy(coverURL = cover.url, coverData = Blob(cover.data))
            val candidate = cover.candidate
            // A Kitsu result never replaces an already selected Shikimori work.
            if (candidate != null && (candidate.shikimoriID != null || expected.sourceID == null)) {
                next = next.copy(sourceID = candidate.shikimoriID, sourceURL = candidate.pageURL, originalTitle = candidate.name).learnNames(candidate.names)
            }
            val origin = cover.imageCatalog?.let { " · ${it.label}" } ?: ""
            next.copy(coverDiscovery = CoverDiscovery(expected.title, "Обложка найдена и сохранена$origin", false))
        }
    }

    /** Remove only recognisable catalogue error images; never touch a user's own photo. */
    fun removePlaceholders(snapshot: Snapshot): Snapshot? {
        if (snapshot.entries.none { CoverImagePolicy.isPlaceholder(it.coverURL) }) return null
        return snapshot.copy(entries = snapshot.entries.map {
            if (CoverImagePolicy.isPlaceholder(it.coverURL)) it.copy(coverData = null, coverURL = "", coverDiscovery = null) else it
        })
    }
}
