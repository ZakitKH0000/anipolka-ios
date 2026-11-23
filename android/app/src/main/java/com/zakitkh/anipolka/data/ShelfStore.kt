package com.zakitkh.anipolka.data

import android.content.Context
import com.zakitkh.anipolka.core.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * The single store shared by the interface, notification actions, the widget and the tile.
 * Every change is written to disk first and published only after the write succeeded.
 */
class ShelfStore private constructor(private val context: Context) {
    private val file = File(context.filesDir, "AniPolka/shelf.json")
    private var repository: ShelfRepository? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var undoJob: Job? = null

    private val _snapshot = MutableStateFlow(Snapshot())
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()
    val error = MutableStateFlow<String?>(null)
    private val _undo = MutableStateFlow<EpisodeUndo?>(null)
    val undo: StateFlow<EpisodeUndo?> = _undo.asStateFlow()
    var loadFailure: String? = null
        private set
    /** A link shared to the app, waiting for the user to attach it to a title. */
    val pendingLink = MutableStateFlow<String?>(null)

    init {
        try {
            repository = ShelfRepository(file)
            _snapshot.value = repository!!.snapshot
        } catch (e: Exception) {
            loadFailure = "Локальный файл не удалось прочитать. Он сохранён без изменений. Восстановите резервную копию в настройках.\n${e.message ?: ""}"
        }
        NoticeInbox.tidy(_snapshot.value).takeIf { it !== _snapshot.value && repository != null }?.let { tidied ->
            try { repository?.commit(tidied); _snapshot.value = repository!!.snapshot } catch (_: Exception) {}
        }
        CoverRepair.removePlaceholders(_snapshot.value)?.let { repaired ->
            try { repository?.commit(repaired); _snapshot.value = repaired } catch (e: Exception) { error.value = "Не удалось удалить заглушку обложки: ${e.message}" }
        }
    }

    val current: Snapshot get() = _snapshot.value

    fun change(block: (Snapshot) -> Snapshot): Boolean = synchronized(this) {
        val repo = repository ?: run { error.value = loadFailure; return false }
        return try {
            val next = block(repo.snapshot)
            if (next !== repo.snapshot) repo.commit(next)
            _snapshot.value = repo.snapshot
            integrations()
            true
        } catch (e: Exception) { error.value = "Не удалось сохранить: ${e.message}"; false }
    }

    fun save(entry: Entry) = change { it.save(entry) }

    /** Also used by the notification action, the tile and shortcuts, so it reports the new progress. */
    fun increment(id: UUID, by: Int = 1): Entry? = synchronized(this) {
        val repo = repository ?: return null
        return try {
            val token = repo.increment(id, by) ?: return null
            _snapshot.value = repo.snapshot
            _undo.value = token
            integrations()
            undoJob?.cancel(); undoJob = scope.launch { delay(6000); _undo.value = null }
            token.applied
        } catch (e: Exception) { error.value = e.message; null }
    }

    fun undoLast() = synchronized(this) {
        val token = _undo.value ?: return
        val repo = repository ?: return
        try { repo.undo(token); _snapshot.value = repo.snapshot; _undo.value = null; undoJob?.cancel(); integrations() }
        catch (e: Exception) { error.value = e.message }
    }

    fun cacheCover(id: UUID, url: String, data: ByteArray) {
        val e = current.entry(id) ?: return
        if (CoverImagePolicy.usableURL(url) == null || e.coverURL != url || e.coverData != null) return
        change { s -> s.withEntry(id) { it.copy(coverData = Blob(data)) } }
    }

    fun restore(backup: Snapshot, replacing: Boolean): Boolean = synchronized(this) {
        try {
            val validated = backup.validated().let { CoverRepair.removePlaceholders(it) ?: it }
            if (repository == null) {
                if (!replacing) { error.value = "Для повреждённой коллекции выберите восстановление с заменой."; return false }
                // Keep the unreadable file for recovery before restoring a known-valid copy.
                if (file.exists()) {
                    file.copyTo(File(file.parentFile, "unreadable-${UUID.randomUUID()}.json"))
                    file.writeBytes(validated.encoded())
                }
                repository = ShelfRepository(file)
            }
            val ok = change { if (replacing) validated else it.merged(validated) }
            if (ok) { loadFailure = null; _undo.value = null }
            ok
        } catch (e: Exception) { error.value = e.message; false }
    }

    fun setPreferences(block: (Preferences) -> Preferences) = change { it.copy(preferences = block(it.preferences)) }

    /** Widget and reminders follow every saved change, including ones made from notifications or the tile. */
    private fun integrations() {
        Integrations.update(context, _snapshot.value)
    }

    companion object {
        @Volatile private var instance: ShelfStore? = null
        fun get(context: Context): ShelfStore = instance ?: synchronized(this) {
            instance ?: ShelfStore(context.applicationContext).also { instance = it }
        }
        fun nowInstant(): Instant = Instant.now()
    }
}
