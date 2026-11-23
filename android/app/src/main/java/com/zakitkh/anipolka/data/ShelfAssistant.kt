package com.zakitkh.anipolka.data

import android.content.Context
import com.zakitkh.anipolka.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

/** Automatic covers, release checks and AniVibe lookup. */
class ShelfAssistant private constructor(private val context: Context) {
    private val store = ShelfStore.get(context)
    private val network = NetworkService.get(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var coverJob: Job? = null
    private val coverAttempts = HashMap<UUID, Instant>()
    val checking = MutableStateFlow(false)
    val findingCovers = MutableStateFlow(false)
    val message = MutableStateFlow<String?>(null)
    private var anivibePages: Pair<Instant, List<AnivibeCatalog.Page>>? = null

    fun queueCovers(force: Boolean = false) {
        if (coverJob?.isActive == true || store.loadFailure != null || !network.canLoadCovers) return
        if (!force && !store.current.preferences.automaticCovers) return
        coverJob = scope.launch {
            findingCovers.value = true
            var continueBatch = false
            try {
                val now = Instant.now()
                val ids = store.current.entries.filter { e ->
                    if (e.coverData != null || e.coverLookupDisabled == true) return@filter false
                    val attempt = coverAttempts[e.id]
                    if (!force && e.coverDiscovery?.query == e.title && attempt != null && now.epochSecond - attempt.epochSecond < 60) return@filter false
                    force || e.coverDiscovery?.query != e.title || now.epochSecond - (e.coverDiscovery?.checkedAt?.epochSecond ?: 0) > 86400
                }.take(30).map { it.id }
                continueBatch = ids.size == 30
                for (id in ids) {
                    if (!isActive || !(force || store.current.preferences.automaticCovers) || !network.canLoadCovers) break
                    val entry = store.current.entry(id) ?: continue
                    if (entry.coverData != null || entry.coverLookupDisabled == true) continue
                    coverAttempts[id] = Instant.now()
                    try {
                        when (val result = network.automaticCover(entry)) {
                            is CoverResolution.Found -> store.change { s -> CoverRepair.apply(s, result.cover, entry) ?: s }
                            is CoverResolution.NotFound -> setDiscovery(entry,
                                if (result.needsChoice) "Найдены похожие произведения. Выберите подходящую обложку." else "В доступных каталогах настоящая обложка не найдена. Поиск можно повторить позже.",
                                result.needsChoice)
                        }
                    } catch (e: CancellationException) { throw e } catch (e: Exception) {
                        setDiscovery(entry, "Не удалось загрузить обложку. Можно повторить поиск.", false)
                    }
                }
            } finally {
                findingCovers.value = false
                coverJob = null
                if (continueBatch) queueCovers()
            }
        }
    }

    private fun setDiscovery(entry: Entry, message: String, needsChoice: Boolean) = store.change { s ->
        val cur = s.entry(entry.id)
        if (cur == null || cur.title != entry.title || cur.coverURL != entry.coverURL || cur.coverData != entry.coverData || cur.coverLookupDisabled == true) s
        else s.withEntry(entry.id) { it.copy(coverDiscovery = CoverDiscovery(entry.title, message, needsChoice)) }
    }

    /** Pages whose address matches any known name of the entry. The list is cached for a day. */
    suspend fun anivibeCandidates(entry: Entry): List<AnivibeCatalog.Page> {
        val cached = anivibePages
        if (cached == null || Instant.now().epochSecond - cached.first.epochSecond > 86400) {
            val index = network.anivibeSitemap(AnivibeCatalog.SITEMAP_INDEX)
            val locations = mutableListOf<String>()
            for (file in AnivibeCatalog.sitemapFiles(index)) locations += AnivibeCatalog.locations(network.anivibeSitemap(file))
            anivibePages = Instant.now() to AnivibeCatalog.pages(locations)
        }
        return AnivibeCatalog.candidates(entry, anivibePages?.second ?: emptyList())
    }

    suspend fun readPage(address: String): SourcePage {
        val url = AnivibePageParser.canonicalURL(address) ?: throw ShelfError("Вставьте HTTPS-ссылку на страницу произведения: anivibe.pro/anime/…")
        return AnivibePageParser.parse(network.sourcePage(url), url)
    }

    fun connect(page: SourcePage, option: SourceOption, entryID: UUID) = store.change { s ->
        val e = s.entry(entryID) ?: return@change s
        val attached = e.attachSource(page, option) ?: return@change s
        s.withEntry(entryID) { attached }
    }

    val refreshingAiring = MutableStateFlow(false)

    /** Next-episode times, aired counts and continuations from Shikimori for titles whose data is stale. */
    suspend fun refreshAiring(force: Boolean = false): Int {
        if (refreshingAiring.value || store.loadFailure != null || !store.current.preferences.catalogUpdates || !network.connected.value) return 0
        refreshingAiring.value = true
        try {
            val now = Instant.now()
            val due = store.current.entries.filter { e -> e.sourceID != null && e.status != WatchStatus.DROPPED && (force || Airing.needsRefresh(e, now)) }
            var updated = 0
            for (chunk in due.mapNotNull { it.sourceID }.distinct().chunked(50)) {
                val found = network.airing(chunk)
                if (found.isEmpty()) continue
                store.change { s -> s.copy(entries = s.entries.map { e -> found[e.sourceID]?.let { updated++; Airing.apply(e, it) } ?: e }) }
            }
            return updated
        } catch (e: CancellationException) { throw e } catch (_: Exception) { return 0 }
        finally { refreshingAiring.value = false }
    }

    /** Reads every enabled source; a background run checks at most 8 that were not checked within an hour. */
    suspend fun checkReleases(background: Boolean = false): Int {
        if (checking.value || (background && !store.current.preferences.backgroundChecks)) return 0
        checking.value = true
        if (!background) message.value = null
        var newCount = 0; var errors = 0
        val work = store.current.entries.flatMap { e -> e.subscriptions.filter { it.enabled }.map { Triple(e.id, it, it.lastCheckedAt) } }
            .sortedBy { it.third ?: Instant.MIN }
        try {
            val pages = HashMap<String, SourcePage>()
            for ((entryID, source, lastChecked) in work.take(if (background) 8 else 60)) {
                if (background && lastChecked != null && Instant.now().epochSecond - lastChecked.epochSecond < 3600) continue
                try {
                    val page = pages[source.pageURL] ?: readPage(source.pageURL).also { pages[source.pageURL] = it }
                    val current = store.current.entry(entryID) ?: continue
                    val (updated, found) = ReleaseTracker.observe(page, current, source.id)
                    val committed = store.change { s ->
                        val now = s.entry(entryID)
                        // The network answer must not overwrite parallel edits of progress or notes.
                        if (now == null || now.subscriptions != current.subscriptions) s
                        else s.withEntry(entryID) { it.copy(subscriptions = updated.subscriptions, releaseNotices = updated.releaseNotices) }
                    }
                    // An episode the user already marked as watched is filed as read and does not ring.
                    val unread = store.current.entry(entryID)?.releaseNotices?.any { it.id == found?.id && !it.read } == true
                    if (committed && found != null && unread) {
                        newCount++
                        if (store.current.preferences.releaseNotifications) Notifications.release(context, found, entryID)
                    }
                } catch (e: CancellationException) { throw e } catch (e: Exception) {
                    errors++
                    store.change { s -> s.withEntry(entryID) { en ->
                        en.copy(subscriptions = en.subscriptions.map { if (it.id == source.id) it.copy(error = e.message, lastCheckedAt = Instant.now()) else it })
                    } }
                }
            }
        } finally { checking.value = false }
        refreshAiring()
        if (!background) message.value = if (work.isEmpty()) "Выберите источник в карточке произведения."
            else "Проверено источников: ${minOf(work.size, 60)}. Новых выпусков: $newCount." + if (errors > 0) " Недоступно: $errors. Подробности — в карточках." else ""
        return newCount
    }

    companion object {
        @Volatile private var instance: ShelfAssistant? = null
        fun get(context: Context): ShelfAssistant = instance ?: synchronized(this) { instance ?: ShelfAssistant(context.applicationContext).also { instance = it } }
    }
}
