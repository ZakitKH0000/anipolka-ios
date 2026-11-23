package com.zakitkh.anipolka.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.zakitkh.anipolka.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** Catalogue search, AniVibe pages and covers. Requests are spaced out and 429 pauses each host separately. */
class NetworkService private constructor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    val connected = MutableStateFlow(false)
    val wifi = MutableStateFlow(false)
    @Volatile var wifiOnly = false
    private val metaLock = Mutex()
    private val sourceLock = Mutex()
    private var nextRequest = 0L
    private var nextSourceRequest = 0L
    private val cooldowns = HashMap<String, Long>()

    init {
        refresh()
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh()
            override fun onLost(network: Network) = refresh()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = refresh()
        })
    }

    private fun refresh() {
        val caps = connectivity.activeNetwork?.let { connectivity.getNetworkCapabilities(it) }
        connected.value = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        wifi.value = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true || caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
    }

    val canLoadCovers: Boolean get() = CoverPolicy.permits(wifiOnly, connected.value, wifi.value)

    private suspend fun metadata(url: String, body: String? = null): String {
        val host = URL(url).host
        metaLock.withLock {
            if (System.currentTimeMillis() < (cooldowns[host] ?: 0)) throw ShelfError("Каталог просит подождать. Повторите поиск через минуту.")
            val wait = nextRequest - System.currentTimeMillis()
            nextRequest = System.currentTimeMillis() + maxOf(0, wait) + 1000
            if (wait > 0) delay(wait)
        }
        currentCoroutineContext().ensureActive()
        return withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 20_000; c.readTimeout = 20_000
                c.setRequestProperty("User-Agent", "AniPolka/1.2 (personal Android collection)")
                if (host == "kitsu.io") c.setRequestProperty("Accept", "application/vnd.api+json")
                if (body != null) {
                    c.requestMethod = "POST"; c.doOutput = true; c.setRequestProperty("Content-Type", "application/json")
                    c.outputStream.use { it.write(body.toByteArray()) }
                }
                val code = c.responseCode
                if (code == 429) {
                    val retry = c.getHeaderField("Retry-After")?.toLongOrNull() ?: 60
                    synchronized(cooldowns) { cooldowns[host] = System.currentTimeMillis() + retry * 1000 }
                    throw ShelfError("Слишком много запросов. Повторите через минуту.")
                }
                if (code != 200) throw ShelfError("Каталог недоступен ($code). Можно добавить запись вручную.")
                c.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)
            } finally { c.disconnect() }
        }
    }

    suspend fun search(text: String, catalog: AnimeCatalog = AnimeCatalog.SHIKIMORI): List<AnimeCandidate> {
        if (catalog == AnimeCatalog.KITSU) {
            val q = URLEncoder.encode(text, "UTF-8")
            return CatalogJson.kitsu(metadata("https://kitsu.io/api/edge/anime?filter%5Btext%5D=$q&page%5Blimit%5D=20"))
        }
        try { return shikimoriGraphQL("search: \$value", text) }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
        // Legacy REST is still useful for title identity; its missing-image URLs are filtered out.
        return CatalogJson.shikimoriREST(metadata("https://shikimori.io/api/animes?search=${URLEncoder.encode(text, "UTF-8")}&limit=30&censored=true"))
    }

    private suspend fun shikimoriGraphQL(filter: String, value: String): List<AnimeCandidate> {
        val query = "query(\$value: String!) { animes($filter, limit: 30, censored: true) { id name russian english japanese synonyms url kind episodes airedOn { year month day } poster { originalUrl mainUrl } } }"
        val body = JSONObject().put("query", query).put("variables", JSONObject().put("value", value)).toString()
        return CatalogJson.shikimoriGraphQL(metadata("https://shikimori.io/api/graphql", body))
    }

    suspend fun shikimoriCandidate(id: Int): AnimeCandidate? {
        try { return shikimoriGraphQL("ids: \$value", id.toString()).firstOrNull { it.id == id } }
        catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) {}
        return CatalogJson.shikimoriRESTOne(metadata("https://shikimori.io/api/animes/$id"))?.takeIf { it.id == id }
    }

    /** Broadcast data for up to 50 titles in one request; only catalogue IDs are sent. */
    suspend fun airing(ids: List<Int>): Map<Int, AiringInfo> =
        if (ids.isEmpty()) emptyMap() else Airing.parse(metadata("https://shikimori.io/api/graphql", Airing.query(ids.take(50))))

    suspend fun alternatives(id: Int): List<String> {
        val array = org.json.JSONArray(metadata("https://shikimori.io/api/animes/$id/screenshots"))
        return (0 until minOf(array.length(), 16)).mapNotNull { i ->
            array.optJSONObject(i)?.optString("original")?.takeIf { it.isNotEmpty() }?.let { java.net.URI("https://shikimori.io/").resolve(it).toString() }
        }
    }

    suspend fun automaticCover(entry: Entry) = AutomaticCoverLookup.resolve(entry,
        search = { t, c -> search(t, c) }, lookup = { shikimoriCandidate(it) }, download = { image(it) })

    private suspend fun spacedSource() = sourceLock.withLock {
        val wait = nextSourceRequest - System.currentTimeMillis()
        nextSourceRequest = System.currentTimeMillis() + maxOf(0, wait) + 1200
        if (wait > 0) delay(wait)
    }

    /** Public sitemap files of AniVibe; the site's search is closed to automated requests by robots.txt. */
    suspend fun anivibeSitemap(url: String): String {
        val u = URL(url)
        if (u.protocol != "https" || u.host != "anivibe.pro" || !u.path.endsWith(".xml")) throw ShelfError("Недопустимый адрес.")
        spacedSource()
        return withContext(Dispatchers.IO) {
            val c = u.openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 30_000; c.readTimeout = 30_000
                c.setRequestProperty("User-Agent", "AniPolka/1.2 (personal episode tracker)")
                val data = if (c.responseCode == 200 && c.url.host == "anivibe.pro") c.inputStream.use { readLimited(it, 30_000_000) } else null
                data?.toString(Charsets.UTF_8) ?: throw ShelfError("Список страниц AniVibe сейчас недоступен. Вставьте ссылку вручную.")
            } finally { c.disconnect() }
        }
    }

    suspend fun sourcePage(url: String): String {
        spacedSource()
        return withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 20_000; c.readTimeout = 20_000
                c.setRequestProperty("User-Agent", "AniPolka/1.2 (personal episode tracker)")
                if (c.responseCode != 200 || AnivibePageParser.canonicalURL(c.url.toString()) == null)
                    throw ShelfError("AniVibe временно недоступен или требует входа. Проверка не изменила данные источника.")
                c.inputStream.use { readLimited(it, 8_000_000) ?: throw ShelfError("Страница источника слишком большая.") }.toString(Charsets.UTF_8)
            } finally { c.disconnect() }
        }
    }

    suspend fun image(address: String): ByteArray {
        if (!canLoadCovers) throw ShelfError("Загрузка обложек ожидает Wi-Fi или подключения к сети.")
        val url = CoverImagePolicy.usableURL(address) ?: throw ShelfError("Недопустимый адрес обложки.")
        val raw = withContext(Dispatchers.IO) {
            val c = URL(url).openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 20_000; c.readTimeout = 30_000
                c.setRequestProperty("User-Agent", "AniPolka/1.2")
                val code = c.responseCode
                if (!CoverImagePolicy.acceptsResponse(code, c.contentType?.substringBefore(';')?.trim(), c.url.toString())) throw ShelfError("Обложка недоступна.")
                c.inputStream.use { readLimited(it, 12_000_000) } ?: throw ShelfError("Изображение слишком большое.")
            } finally { c.disconnect() }
        }
        currentCoroutineContext().ensureActive()
        if (!canLoadCovers) throw ShelfError("Загрузка обложек ожидает Wi-Fi.")
        return withContext(Dispatchers.Default) { normalized(raw) } ?: throw ShelfError("Обложка недоступна или повреждена.")
    }

    private fun readLimited(input: java.io.InputStream, limit: Int): ByteArray? {
        val out = ByteArrayOutputStream(); val buffer = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buffer); if (n < 0) break
            out.write(buffer, 0, n); if (out.size() > limit) return null
        }
        return out.toByteArray()
    }

    companion object {
        @Volatile private var instance: NetworkService? = null
        fun get(context: Context): NetworkService = instance ?: synchronized(this) { instance ?: NetworkService(context.applicationContext).also { instance = it } }

        /** Re-encodes any picture as JPEG of at most 1200 px, like the iOS app. */
        fun normalized(data: ByteArray): ByteArray? {
            if (data.size > 20_000_000) return null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 1200) sample *= 2
            val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
            val scale = 1200f / maxOf(bitmap.width, bitmap.height)
            val sized = if (scale < 1f) Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true) else bitmap
            return ByteArrayOutputStream().also { sized.compress(Bitmap.CompressFormat.JPEG, 82, it) }.toByteArray()
        }
    }
}
