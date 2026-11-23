package com.zakitkh.anipolka.core

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** What goes into the text the user copies out of the app. */
data class ReportOptions(
    val style: Style = Style.DETAILED,
    val statuses: Set<WatchStatus> = WatchStatus.entries.toSet(),
    /** «Где остановился» and the free-form note. */
    val notes: Boolean = true,
    val links: Boolean = false,
    val statistics: Boolean = true,
) {
    enum class Style(val label: String) { BRIEF("Кратко"), DETAILED("Подробно"), FOR_AI("Для ИИ") }
}

/** A plain-text copy of the collection. Everything comes from the local file; nothing is sent anywhere. */
object ShelfReport {
    private val ruDate = DateTimeFormatter.ofPattern("d MMMM yyyy", Locale("ru"))

    fun text(snapshot: Snapshot, options: ReportOptions = ReportOptions(), now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
        val blocks = mutableListOf<String>()
        if (options.style == ReportOptions.Style.FOR_AI) blocks += aiHeader(now, zone)
        val separator = if (options.style == ReportOptions.Style.DETAILED) "\n\n" else "\n"
        val groups = WatchStatus.entries.filter { it in options.statuses }.mapNotNull { status ->
            val entries = snapshot.visible(status = status)
            if (entries.isEmpty()) null else "${status.raw} (${entries.size}):\n" + entries.joinToString(separator) { block(it, options, now, zone) }
        }
        blocks += if (groups.isEmpty()) "Список пуст или ничего не выбрано." else groups.joinToString("\n\n")
        if (options.statistics) blocks += statistics(snapshot, now, zone)
        if (options.style == ReportOptions.Style.FOR_AI) blocks += "Мой вопрос: "
        return blocks.joinToString("\n\n")
    }

    private fun aiHeader(now: Instant, zone: ZoneId) =
        "Это мой личный список аниме и дунхуа из приложения АниПолка на ${date(now, zone)}.\n" +
            "Как читать: «остановился на серии N» — последняя серия, которую я посмотрел (нумерация моя, иногда сквозная); «просмотрено: 1–N» — я смотрел подряд до серии N; «Источники» — озвучки, которые я отслеживаю, и последняя доступная в них серия.\n" +
            "Опирайся только на эти данные и прямо говори, если чего-то не знаешь."

    private fun block(entry: Entry, options: ReportOptions, now: Instant, zone: ZoneId): String {
        if (options.style == ReportOptions.Style.BRIEF) return "• ${entry.title} — ${progress(entry)}"
        val lines = mutableListOf("• " + entry.title + otherNames(entry), "  Статус: ${entry.status.raw} · ${progress(entry)}")
        sources(entry)?.let { lines += "  Источники: $it" }
        val available = Backlog.available(entry)
        if (available != null) lines += "  Не просмотрено в источнике: $available" else if (Backlog.caughtUp(entry)) lines += "  Догнал: жду новые серии"
        entry.rating?.let { lines += "  Оценка: ${"★".repeat(it)}${"☆".repeat(5 - it)} ($it из 5)" }
        if (entry.tags.isNotEmpty()) lines += "  Метки: " + entry.tags.joinToString(", ")
        val days = ReleasePlanner.days(entry)
        if (days.isNotEmpty()) lines += "  Выходит: $days"
        val premiere = entry.premiereDate
        if (premiere != null && PremierePlanner.upcoming(listOf(entry), now, zone).isNotEmpty()) lines += "  Премьера: " + date(premiere, zone)
        entry.passTitle?.let { lines += "  $it" }
        if (options.notes) {
            entry.resumePoint?.let { p ->
                val time = if (p.time.isEmpty()) "" else " · ${p.time}"
                val text = if (p.text.isEmpty()) "" else " — ${oneLine(p.text)}"
                lines += "  Где остановился: серия ${p.episode}$time$text"
            }
            val note = oneLine(entry.note)
            if (note.isNotEmpty()) lines += "  Заметка: $note"
        }
        entry.watchedAt?.let { lines += "  Последний просмотр: " + date(it, zone) }
        if (options.links) {
            if (entry.watchURL.isNotEmpty()) lines += "  Ссылка: ${entry.watchURL}"
            entry.links.forEach { lines += "  Ссылка (${it.label}): ${it.url}" }
        }
        return lines.joinToString("\n")
    }

    fun progress(entry: Entry): String {
        val parts = mutableListOf<String>()
        entry.season?.let { parts += "сезон $it" }
        parts += when {
            entry.episode == 0 -> "не начато"
            entry.status == WatchStatus.COMPLETED -> "посмотрено до серии ${entry.episode}"
            else -> "остановился на серии ${entry.episode} (просмотрено: ${if (entry.episode <= 1) "серия 1" else "1–${entry.episode}"})"
        }
        return parts.joinToString(", ")
    }

    private fun otherNames(entry: Entry): String {
        val seen = hashSetOf(TitleMatcher.key(entry.title))
        val names = (listOf(entry.originalTitle) + entry.aliases).filter { val k = TitleMatcher.key(it); k.isNotEmpty() && seen.add(k) }.take(3)
        return if (names.isEmpty()) "" else " (" + names.joinToString("; ") + ")"
    }

    private fun sources(entry: Entry): String? {
        val enabled = entry.subscriptions.filter { it.enabled }
        if (enabled.isEmpty()) return null
        return enabled.joinToString(", ") { s -> Dubs.name(s.label) + (s.lastEpisode?.let { " (доступна серия $it)" } ?: "") }
    }

    private fun statistics(snapshot: Snapshot, now: Instant, zone: ZoneId): String {
        val stats = WatchStats.of(snapshot, now, zone)
        val counts = WatchStatus.entries.joinToString(" · ") { "${it.raw} ${stats.byStatus[it] ?: 0}" }
        val lines = mutableListOf("Итоги:", "Историй: ${snapshot.entries.size} ($counts)", "Сумма номеров серий: ${stats.totalEpisodes}")
        val since = stats.trackingSince
        lines += if (since != null) "Отмечено в АниПолке: за 7 дней — ${stats.lastWeek}, за 30 дней — ${stats.lastMonth}, с начала года — ${stats.thisYear} (учёт с ${date(since, zone)})"
        else "Отметки серий в АниПолке пока не ведутся: счёт начнётся с первого «+1»."
        lines += "Завершено в этом году: ${stats.completedThisYear}"
        stats.averageRating?.let { lines += "Средняя оценка: " + String.format(Locale.ROOT, "%.1f", it).replace('.', ',') + " из 5" }
        if (stats.topRated.isNotEmpty()) lines += "Оценка 5 звёзд: " + stats.topRated.joinToString(", ")
        return lines.joinToString("\n")
    }

    private fun oneLine(text: String): String {
        val flat = text.lines().map { it.trim() }.filter { it.isNotEmpty() }.joinToString(" ")
        return if (flat.length > 300) flat.take(300) + "…" else flat
    }

    fun date(instant: Instant, zone: ZoneId = ZoneId.systemDefault()): String = ruDate.format(ZonedDateTime.ofInstant(instant, zone))
}
