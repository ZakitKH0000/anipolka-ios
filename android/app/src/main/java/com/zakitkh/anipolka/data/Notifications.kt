package com.zakitkh.anipolka.data

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.zakitkh.anipolka.MainActivity
import com.zakitkh.anipolka.R
import com.zakitkh.anipolka.core.AnivibePageParser
import com.zakitkh.anipolka.core.ReleaseNotice
import java.util.UUID

object Notifications {
    const val RELEASES = "releases"
    const val REMINDERS = "reminders"
    const val ACTION_MARK = "com.zakitkh.anipolka.MARK_FROM_NOTIFICATION"

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(RELEASES, "Новые серии", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Новые серии выбранных источников AniVibe"
        })
        manager.createNotificationChannel(NotificationChannel(REMINDERS, "Сводка и премьеры", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Сводка в дни выхода и напоминания о премьерах"
        })
    }

    fun allowed(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun openApp(context: Context, code: Int) = PendingIntent.getActivity(context, code,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_IMMUTABLE)

    fun release(context: Context, notice: ReleaseNotice, entryID: UUID) {
        if (!allowed(context)) return
        val code = notice.id.hashCode()
        val open = if (AnivibePageParser.canonicalURL(notice.url) != null)
            PendingIntent.getActivity(context, code, Intent(Intent.ACTION_VIEW, Uri.parse(notice.url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        else openApp(context, code)
        val mark = PendingIntent.getBroadcast(context, code, Intent(context, MarkReceiver::class.java).setAction(ACTION_MARK)
            .putExtra("entryID", entryID.toString()).putExtra("noticeID", notice.id).putExtra("notificationID", code), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(context, RELEASES).setSmallIcon(R.drawable.ic_stat_shelf)
            .setContentTitle("Новая серия · ${notice.title}")
            .setContentText("AniVibe · ${notice.sourceLabel ?: "Выбранная дорожка"}: серия ${notice.episode}. Нажмите, чтобы открыть просмотр.")
            .setStyle(NotificationCompat.BigTextStyle())
            .setContentIntent(open).setAutoCancel(true)
            .addAction(0, "+1 · Отметить серию просмотренной", mark)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(code, n) }
    }

    fun reminder(context: Context, id: Int, title: String, body: String) {
        if (!allowed(context)) return
        val n = NotificationCompat.Builder(context, REMINDERS).setSmallIcon(R.drawable.ic_stat_shelf)
            .setContentTitle(title).setContentText(body).setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openApp(context, id)).setAutoCancel(true).build()
        runCatching { NotificationManagerCompat.from(context).notify(id, n) }
    }
}

/** «+1» straight from the new-episode notification; works without opening the app. */
class MarkReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Notifications.ACTION_MARK) return
        val id = intent.getStringExtra("entryID")?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return
        val store = ShelfStore.get(context)
        if (store.increment(id) != null) {
            intent.getStringExtra("noticeID")?.let { noticeID ->
                store.change { s -> s.withEntry(id) { e -> e.copy(releaseNotices = e.releaseNotices.map { if (it.id == noticeID) it.copy(read = true) else it }) } }
            }
        }
        NotificationManagerCompat.from(context).cancel(intent.getIntExtra("notificationID", 0))
    }
}
