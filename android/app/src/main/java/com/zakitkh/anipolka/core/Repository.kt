package com.zakitkh.anipolka.core

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.UUID

class ShelfRepository(val file: File) {
    var snapshot: Snapshot = if (file.exists()) Snapshot.decode(file.readBytes()) else Snapshot()
        private set

    /** Atomic replacement: the in-memory state changes only after the disk write succeeds. */
    fun commit(proposed: Snapshot) {
        val next = NoticeInbox.tidy(proposed)
        val data = next.encoded()
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, ".${file.name}.${UUID.randomUUID()}.tmp")
        try {
            temp.outputStream().use { it.write(data); it.fd.sync() }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } finally { temp.delete() }
        snapshot = next
    }

    fun increment(id: UUID, by: Int = 1, now: Instant = Instant.now()): EpisodeUndo? {
        if (by <= 0) return null
        val previous = snapshot.entry(id) ?: return null
        if (previous.episode >= 1_000_000) return null
        val step = minOf(by, 1_000_000 - previous.episode)
        val applied = previous.copy(episode = previous.episode + step, watchedAt = now, updatedAt = now)
        commit(snapshot.withEntry(id) { applied }.recordWatch(id, step, now))
        return EpisodeUndo(id, previous, applied)
    }

    fun undo(token: EpisodeUndo) {
        val current = snapshot.entry(token.id) ?: return
        if (current.episode != token.applied.episode || current.watchedAt != token.applied.watchedAt) return
        var next = snapshot.withEntry(token.id) { e ->
            e.copy(episode = token.previous.episode, watchedAt = token.previous.watchedAt,
                updatedAt = if (e.updatedAt == token.applied.updatedAt) token.previous.updatedAt else e.updatedAt)
        }
        val at = token.applied.watchedAt
        val j = next.history.indexOfLast { it.entryID == token.id && it.at == at }
        if (at != null && j >= 0) next = next.copy(history = next.history.toMutableList().also { it.removeAt(j) })
        commit(next)
    }
}
