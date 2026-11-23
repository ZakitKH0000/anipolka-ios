package com.zakitkh.anipolka.widget

import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.zakitkh.anipolka.core.ReleasePlanner
import com.zakitkh.anipolka.data.ShelfStore

/** «+1 серия» in the quick settings panel: marks the next episode of the title watched last. */
class MarkTileService : TileService() {
    override fun onStartListening() = render(null)

    override fun onClick() {
        val store = ShelfStore.get(this)
        val entry = ReleasePlanner.continuing(store.current.entries, 1).firstOrNull()
        val updated = entry?.let { store.increment(it.id) }
        render(updated?.let { "«${it.title}»: серия ${it.episode}" } ?: "Нет историй «Смотрю»")
    }

    private fun render(status: String?) {
        val tile = qsTile ?: return
        val entry = ReleasePlanner.continuing(ShelfStore.get(this).current.entries, 1).firstOrNull()
        tile.label = "+1 серия"
        tile.state = if (entry != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = status ?: entry?.let { "${it.title} · ${it.episode}" } ?: "АниПолка"
        tile.updateTile()
    }
}
