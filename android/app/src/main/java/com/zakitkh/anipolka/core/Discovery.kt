package com.zakitkh.anipolka.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.text.Collator
import java.text.Normalizer
import java.time.Instant
import java.util.Locale
import java.util.UUID

object TitleIdentity {
    private val ru = Locale("ru", "RU")
    private val marks = Regex("\\p{Mn}+")
    private val separators = Regex("[^\\p{L}\\p{N}]+")
    private val collator: Collator = Collator.getInstance(ru).apply { strength = Collator.SECONDARY }

    /** Case, accents and «ё» are ignored, punctuation becomes single spaces (like Swift's folding). */
    fun normalized(title: String): String {
        val folded = Normalizer.normalize(title.lowercase(ru), Normalizer.Form.NFD).replace(marks, "").replace("ё", "е")
        return folded.split(separators).filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** Автоматически выбирается только единственное точное совпадение названия, без угадывания сезона. */
    fun uniqueExactMatch(query: String, candidates: List<List<String>>): Int? {
        val key = normalized(query)
        if (key.length < 3) return null
        val matches = candidates.indices.filter { i -> candidates[i].any { normalized(it) == key } }
        return if (matches.size == 1) matches[0] else null
    }

    fun query(title: String) = title.replace("⭐", "").replace("★", "").trim()

    fun compareStandard(a: String, b: String) = collator.compare(a, b)
}

data class SourceOption(
    val id: String,
    val label: String,
    val episode: Int,
    val translationID: Int? = null,
    val translationKey: String? = null,
    val player: String = "kodik",
)

data class SourcePage(
    val title: String,
    val url: String,
    val coverURL: String?,
    val options: List<SourceOption>,
    /** Every title the page gives for the work: Russian, English and alternative names. */
    val names: List<String> = emptyList(),
) {
    fun watchURL(option: SourceOption, episode: Int): String {
        // Публичная страница поддерживает episode и translation. Видеопотоки не извлекаются.
        fun enc(v: String) = URLEncoder.encode(v, "UTF-8").replace("+", "%20")
        val query = buildList {
            add("episode=$episode")
            option.translationKey?.let { add("translation=${enc(it)}") }
            add("player=${enc(option.player)}")
        }.joinToString("&")
        return "${url.substringBefore('?').substringBefore('#')}?$query#player-section"
    }
}

object AnivibePageParser {
    private val pathPattern = Regex("^/anime/[0-9]+(?:-[a-zA-Z0-9_-]+)?/?$")

    fun canonicalURL(text: String): String? = try {
        val uri = URI(text.trim())
        val host = uri.host?.lowercase()
        if (uri.scheme?.lowercase() != "https" || host !in setOf("anivibe.pro", "www.anivibe.pro") || uri.rawUserInfo != null || uri.port != -1) null
        else uri.rawPath?.takeIf { pathPattern.matches(it) }?.let { "https://anivibe.pro$it" }
    } catch (e: Exception) { null }

    fun parse(html: String, url: String): SourcePage {
        val canonical = canonicalURL(url)
        if (canonical == null || html.toByteArray().size > 8_000_000)
            throw ShelfError("Страница AniVibe не содержит распознаваемого списка серий. Формат сайта мог измениться; текущие данные сохранены.")
        val root = runCatching { JSONObject(jsonValue(html, "const kodikData =") ?: "{}") }.getOrDefault(JSONObject())
        val rows = root.optJSONArray("translations") ?: JSONArray()
        val material = root.optJSONObject("material_data") ?: JSONObject()
        val title = (material.opt("anime_title") as? String) ?: (material.opt("title") as? String) ?: meta("og:title", html) ?: "AniVibe"
        val seen = HashSet<String>(); val options = mutableListOf<SourceOption>()
        for (i in 0 until rows.length()) {
            val row = rows.optJSONObject(i) ?: continue
            val id = integer(row.opt("id")) ?: continue
            val label = row.opt("title") as? String ?: continue
            val episode = integer(row.opt("last_episode"))?.takeIf { it in 1..1_000_000 } ?: continue
            val season = integer(row.opt("season"))
            val key = "kodik-$id-${season ?: 0}"
            if (!seen.add(key)) continue
            options += SourceOption(key, label + (season?.let { " · сезон $it" } ?: "") + " · Kodik", episode, id, label)
        }
        // Только публичные номера серий и названия дорожек; коды видео и signed_params не сохраняются.
        jsonValue(html, "window.__vidozaData = window.__unpackVidozaGroups(")?.let { raw ->
            val groups = runCatching { JSONArray(raw) }.getOrNull() ?: return@let
            for (i in 0 until groups.length()) {
                val group = groups.optJSONObject(i) ?: continue
                val author = (group.opt("vn") as? String)?.takeIf { it.length <= 80 } ?: continue
                val episodes = group.optJSONArray("eps") ?: continue
                val last = (0 until episodes.length()).mapNotNull { integer(episodes.optJSONObject(it)?.opt("e")) }.filter { it in 1..1_000_000 }.maxOrNull() ?: continue
                val type = group.opt("tt") as? String ?: "voice"
                val language = group.opt("tl") as? String ?: "ru"
                if (type !in setOf("voice", "sub", "raw") || language.length > 10) continue
                val track = "$type||$language||$author"; val key = "anivibe-$track"
                if (!seen.add(key)) continue
                val kind = when (type) { "sub" -> "субтитры"; "raw" -> "оригинал"; else -> "озвучка" }
                options += SourceOption(key, "$author · $kind $language · AniVibe", last, null, track, "anivibe")
            }
        }
        if (options.isEmpty()) throw ShelfError("На странице пока нет доступных данных о сериях для отслеживания.")
        val names = listOf("anime_title", "title", "title_en", "title_orig").mapNotNull { material.opt(it) as? String } +
            listOf("other_titles", "other_titles_en").flatMap { key -> material.optJSONArray(key)?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String } } ?: emptyList() }
        return SourcePage(decodeEntities(title), canonical, meta("og:image", html), options, Aliases.merge(emptyList(), names.map(::decodeEntities), emptyList()))
    }

    private fun integer(value: Any?): Int? = (value as? Number)?.let { if (it.toDouble() % 1.0 == 0.0) it.toInt() else null }

    /** Извлекает один JSON-объект без выполнения JavaScript и без чтения закрытых API сайта. */
    fun jsonValue(text: String, marker: String): String? {
        val start = text.indexOf(marker).takeIf { it >= 0 } ?: return null
        var first = start + marker.length
        while (first < text.length && text[first].isWhitespace()) first++
        if (first >= text.length || (text[first] != '{' && text[first] != '[')) return null
        var depth = 0; var inString = false; var escaped = false
        for (i in first until text.length) {
            val ch = text[i]
            if (inString) {
                if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') inString = false
            } else if (ch == '"') inString = true
            else if (ch == '{' || ch == '[') depth++
            else if (ch == '}' || ch == ']') { depth--; if (depth == 0) return text.substring(first, i + 1) }
        }
        return null
    }

    private val metaTag = Regex("<meta\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val content = Regex("content\\s*=\\s*\"([^\"]*)\"", RegexOption.IGNORE_CASE)
    private fun meta(name: String, html: String): String? = metaTag.findAll(html).map { it.value }
        .firstOrNull { it.contains("\"$name\"", ignoreCase = true) && content.containsMatchIn(it) }
        ?.let { content.find(it)?.groupValues?.get(1) }?.let(::decodeEntities)

    fun decodeEntities(text: String) = text.replace("&amp;", "&").replace("&quot;", "\"").replace("&#039;", "'").replace("&lt;", "<").replace("&gt;", ">")
}

object ReleaseTracker {
    /** Первая проверка устанавливает базу. Уведомления только о последующих новых сериях. */
    fun observe(page: SourcePage, entry: Entry, subscriptionID: UUID, now: Instant = Instant.now()): Pair<Entry, ReleaseNotice?> {
        val subscriptions = entry.subscriptions.toMutableList()
        val i = subscriptions.indexOfFirst { it.id == subscriptionID }
        if (i < 0 || !subscriptions[i].enabled) return entry to null
        val old = subscriptions[i]
        val option = page.options.firstOrNull { it.id == old.optionID }
            ?: throw ShelfError("Выбранная озвучка или сезон отсутствует на странице. Выберите источник заново.")
        if (old.lastEpisode != null && option.episode < old.lastEpisode)
            throw ShelfError("Номер серии в источнике уменьшился. Проверьте сезон и озвучку; прежняя отметка сохранена.")
        subscriptions[i] = old.copy(lastCheckedAt = now, lastEpisode = option.episode, error = null)
        val updated = entry.copy(subscriptions = subscriptions)
        val previous = old.lastEpisode
        if (previous == null || option.episode <= previous) return updated to null
        val notice = ReleaseNotice.create(old, entry.title, option.episode, page.watchURL(option, option.episode), now)
        if (updated.releaseNotices.any { it.id == notice.id }) return updated to null
        return updated.copy(releaseNotices = (listOf(notice) + updated.releaseNotices).take(100)) to notice
    }
}
