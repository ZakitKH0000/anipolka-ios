package com.zakitkh.anipolka.data

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.widget.ContinueWidget
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.concurrent.TimeUnit

/** Keeps the widget, background checks and local reminders in step with the collection. */
object Integrations {
    private var lastSignature: String? = null

    fun update(context: Context, snapshot: Snapshot) {
        ContinueWidget.refresh(context, snapshot)
        val prefs = snapshot.preferences
        val sources = snapshot.entries.any { e -> e.subscriptions.any { it.enabled } || e.sourceID != null }
        val signature = "${prefs.backgroundChecks}|$sources|${prefs.dailyDigest}|${prefs.digestMinutes}|" +
            "${prefs.airingReminders}|" + snapshot.entries.joinToString("|") { "${it.id}${it.title}${it.status}${it.releaseDays}${it.premiereDate}${it.airing?.nextEpisodeAt}" }
        if (signature == lastSignature) return
        lastSignature = signature
        val work = WorkManager.getInstance(context)
        if (prefs.backgroundChecks && sources) {
            // Android decides the exact moment, like iOS background refresh: no server, no exact timing.
            work.enqueueUniquePeriodicWork("release-checks", ExistingPeriodicWorkPolicy.KEEP,
                PeriodicWorkRequestBuilder<ReleaseWorker>(6, TimeUnit.HOURS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build())
        } else work.cancelUniqueWork("release-checks")
        Reminders.schedule(context, snapshot)
    }
}

class ReleaseWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        ShelfAssistant.get(applicationContext).checkReleases(background = true)
        return Result.success()
    }
}

/** Daily digest on the user's release days and premiere reminders at 10:00, scheduled one at a time. */
object Reminders {
    private const val PREFS = "reminders"

    data class Due(val at: Instant, val key: String, val title: String, val body: String)

    fun planned(snapshot: Snapshot, from: Instant, zone: ZoneId = ZoneId.systemDefault(), days: Long = 8): List<Due> {
        val result = mutableListOf<Due>()
        val today = ZonedDateTime.ofInstant(from, zone).toLocalDate()
        val prefs = snapshot.preferences
        if (prefs.dailyDigest) for (offset in 0L until days) {
            val day = today.plusDays(offset)
            val titles = ReleasePlanner.due(snapshot.entries, day.dayOfWeek.value % 7 + 1).map { it.title }
            if (titles.isEmpty()) continue
            val at = day.atStartOfDay(zone).plusMinutes(prefs.digestMinutes.toLong()).toInstant()
            result += Due(at, "digest-$day", if (titles.size == 1) "Сегодня выходит новая серия" else "Сегодня выходят новые серии", ReleasePlanner.digestBody(titles))
        }
        for (e in PremierePlanner.upcoming(snapshot.entries, from, zone)) {
            val day = ZonedDateTime.ofInstant(e.premiereDate!!, zone).toLocalDate()
            val at = day.atStartOfDay(zone).plusHours(PremierePlanner.REMINDER_HOUR.toLong()).toInstant()
            result += Due(at, "premiere-${e.id}-$day", "Сегодня премьера", "«${e.title}» — пора смотреть первую серию.")
        }
        if (prefs.airingReminders) for (e in snapshot.entries) {
            if (e.status != WatchStatus.WATCHING && e.status != WatchStatus.PLANNED) continue
            val at = e.airing?.nextEpisodeAt ?: continue
            if (at.isBefore(from) || at.isAfter(from.plusSeconds(days * 86400))) continue
            val episode = Airing.nextEpisode(e, from) ?: continue
            val day = ZonedDateTime.ofInstant(at, zone).toLocalDate()
            result += Due(at, "airing-${e.id}-$episode-$day", "Вышла серия $episode · ${e.title}",
                "По расписанию Shikimori. Озвучка на сайтах обычно появляется позже.")
        }
        return result.sortedBy { it.at }
    }

    fun schedule(context: Context, snapshot: Snapshot) {
        val sent = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet("sent", emptySet()) ?: emptySet()
        val now = Instant.now()
        val next = planned(snapshot, now).firstOrNull { it.key !in sent && it.at.isAfter(now.minusSeconds(3600)) }
        val work = WorkManager.getInstance(context)
        if (next == null) { work.cancelUniqueWork("reminder"); return }
        val delay = Duration.between(now, next.at).toMillis().coerceAtLeast(0)
        work.enqueueUniqueWork("reminder", ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<ReminderWorker>().setInitialDelay(delay, TimeUnit.MILLISECONDS).build())
    }

    fun deliverDue(context: Context, snapshot: Snapshot) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val sent = (prefs.getStringSet("sent", emptySet()) ?: emptySet()).toMutableSet()
        val now = Instant.now()
        for (due in planned(snapshot, now.minusSeconds(86400))) {
            if (due.key in sent || due.at.isAfter(now) || Duration.between(due.at, now).toHours() >= 12) continue
            Notifications.reminder(context, due.key.hashCode(), due.title, due.body)
            sent += due.key
        }
        // Old keys are dropped so the set stays small.
        val cutoff = LocalDate.now().minusDays(10).toString()
        prefs.edit().putStringSet("sent", sent.filter { k -> k.takeLast(10) >= cutoff }.toSet()).apply()
    }
}

class ReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val store = ShelfStore.get(applicationContext)
        Reminders.deliverDue(applicationContext, store.current)
        Reminders.schedule(applicationContext, store.current)
        return Result.success()
    }
}
