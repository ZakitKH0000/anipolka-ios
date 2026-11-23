package com.zakitkh.anipolka.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import com.zakitkh.anipolka.MainActivity
import com.zakitkh.anipolka.R
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.ShelfStore
import java.time.Instant

/**
 * «Продолжить просмотр» on the home screen. Unlike iOS, the widget runs in the app's own
 * process and reads the collection directly, so no shared folder is needed.
 */
class ContinueWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = refresh(context, ShelfStore.get(context).current)

    companion object {
        private val rows = listOf(
            Triple(R.id.row1, R.id.cover1, R.id.title1) to R.id.sub1,
            Triple(R.id.row2, R.id.cover2, R.id.title2) to R.id.sub2,
            Triple(R.id.row3, R.id.cover3, R.id.title3) to R.id.sub3,
        )

        fun refresh(context: Context, snapshot: Snapshot) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ContinueWidget::class.java))
            if (ids.isEmpty()) return
            val views = RemoteViews(context.packageName, R.layout.widget_continue)
            val items = ReleasePlanner.continuing(snapshot.entries, 3)
            val today = ReleasePlanner.due(snapshot.entries, ReleasePlanner.weekday(Instant.now())).size
            views.setTextViewText(R.id.widget_today, if (today > 0) "Сегодня: $today" else "")
            views.setViewVisibility(R.id.widget_empty, if (items.isEmpty()) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(R.id.widget_root, open(context, null, 0))
            rows.forEachIndexed { index, (ids3, sub) ->
                val (row, cover, title) = ids3
                val entry = items.getOrNull(index)
                if (entry == null) { views.setViewVisibility(row, View.GONE); return@forEachIndexed }
                views.setViewVisibility(row, View.VISIBLE)
                views.setTextViewText(title, entry.title)
                views.setTextViewText(sub, "Серия ${entry.episode + 1}" + (Backlog.available(entry)?.let { " · +$it" } ?: ""))
                val bitmap = entry.coverData?.let { thumbnail(it.bytes) }
                if (bitmap != null) views.setImageViewBitmap(cover, bitmap) else views.setImageViewResource(cover, R.drawable.cover_placeholder)
                views.setOnClickPendingIntent(row, open(context, entry, index + 1))
            }
            manager.updateAppWidget(ids, views)
        }

        private fun open(context: Context, entry: Entry?, code: Int): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            entry?.let { intent.putExtra(MainActivity.EXTRA_ENTRY, it.id.toString()) }
            return PendingIntent.getActivity(context, 4000 + code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /** Widgets have a tight memory limit, so covers are reduced to small thumbnails. */
        private fun thumbnail(data: ByteArray): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            var sample = 1
            while (bounds.outHeight / (sample * 2) >= 180) sample *= 2
            return BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
        }
    }
}
