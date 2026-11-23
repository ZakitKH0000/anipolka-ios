package com.zakitkh.anipolka.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.zakitkh.anipolka.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZonedDateTime
import java.util.UUID

@Composable
fun StatsScreen() {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val stats = remember(snapshot) { WatchStats.of(snapshot) }
    val year = ZonedDateTime.now().year
    val summary = remember(snapshot) { YearSummary.of(snapshot, year) }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Итоги", navigator::pop)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            SectionTitle("Отмечено серий")
            Card {
                StatRow("За 7 дней", "${stats.lastWeek} ${episodesWord(stats.lastWeek)}")
                StatRow("За 30 дней", "${stats.lastMonth} ${episodesWord(stats.lastMonth)}")
                StatRow("В этом году", "${stats.thisYear} ${episodesWord(stats.thisYear)}")
                Footnote(stats.trackingSince?.let { "Учитываются отметки в АниПолке начиная с ${ShelfReport.date(it)}." } ?: "Счёт начнётся с первого «+1» или изменения номера серии в карточке.")
            }
            SectionTitle("Коллекция")
            Card {
                StatRow("Сумма номеров ваших серий", "${stats.totalEpisodes}")
                WatchStatus.entries.forEach { StatRow(it.raw, "${stats.byStatus[it] ?: 0}") }
                StatRow("Завершено в этом году", "${stats.completedThisYear}")
            }
            Spacer(Modifier.height(12.dp))
            Card { NavRow("Скопировать всё текстом", Icons.Filled.ContentCopy) { navigator.push(Route.Report) } }
            SectionTitle("Итоги года")
            YearCard(summary, snapshot)
            Spacer(Modifier.height(8.dp))
            IosTintedButton({ scope.launch { shareYearCard(context, summary, snapshot) } }, Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Share, null); Spacer(Modifier.width(8.dp)); Text("Поделиться карточкой")
            }
            SectionTitle("Оценки")
            Card {
                StatRow("Средняя оценка", stats.averageRating?.let { String.format(java.util.Locale.ROOT, "%.1f", it).replace('.', ',') + " ★" } ?: "пока нет")
                stats.topRated.forEach { Text("★★★★★  $it") }
            }
        }
    }
}

@Composable
private fun StatRow(title: String, value: String) = Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
    Text(title, Modifier.weight(1f)); Text(value, color = LocalShelfColors.current.secondaryText)
}

@Composable
private fun YearCard(summary: YearSummary, snapshot: Snapshot) {
    val covers = snapshot.entries.filter { it.title in summary.topRated || it.title == summary.mostWatched }.mapNotNull { it.coverData }.take(4)
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
        .background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(androidx.compose.ui.graphics.Color(0xFF0F1F4D), androidx.compose.ui.graphics.Color(0xFF401A59)))).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("АниПолка ${summary.year}", color = androidx.compose.ui.graphics.Color.White, fontSize = 32.sp, fontWeight = FontWeight.Black)
        if (covers.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            covers.forEach { CoverImage(it, "", Modifier.size(64.dp, 90.dp).clip(RoundedCornerShape(10.dp)), maxSide = 300) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
            YearStat("${summary.episodes}", episodesWord(summary.episodes)); YearStat("${summary.activeDays}", "дней с просмотром"); YearStat("${summary.completed.size}", "завершено")
        }
        summary.mostWatched?.let { Text("Больше всего: $it", color = androidx.compose.ui.graphics.Color.White, fontWeight = FontWeight.SemiBold) }
        if (summary.topRated.isNotEmpty()) Text("★★★★★ " + summary.topRated.take(3).joinToString(" · "), color = Gold)
        Text("Посчитано по отметкам в АниПолке", color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
    }
}

@Composable
private fun YearStat(value: String, title: String) = Column {
    Text(value, color = androidx.compose.ui.graphics.Color.White, fontSize = 26.sp, fontWeight = FontWeight.Bold)
    Text(title, color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.75f), fontSize = 12.sp)
}

/** Draws the year card into a picture only when the user asks to share it. */
private suspend fun shareYearCard(context: Context, s: YearSummary, snapshot: Snapshot) {
    val file = withContext(Dispatchers.Default) {
        val w = 1080; val h = 1350
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bitmap)
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), Paint().apply { shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), 0xFF0F1F4D.toInt(), 0xFF401A59.toInt(), Shader.TileMode.CLAMP) })
        val white = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; typeface = Typeface.DEFAULT_BOLD }
        white.textSize = 110f; c.drawText("АниПолка ${s.year}", 80f, 200f, white)
        var x = 80f
        snapshot.entries.filter { it.title in s.topRated || it.title == s.mostWatched }.mapNotNull { it.coverData }.take(4).forEach { blob ->
            BitmapFactory.decodeByteArray(blob.bytes, 0, blob.size)?.let { cover ->
                c.save(); val rect = RectF(x, 270f, x + 210f, 570f)
                c.clipPath(android.graphics.Path().apply { addRoundRect(rect, 28f, 28f, android.graphics.Path.Direction.CW) })
                c.drawBitmap(cover, null, rect, null); c.restore()
            }
            x += 235f
        }
        val big = Paint(white).apply { textSize = 96f }; val small = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xBFFFFFFF.toInt(); textSize = 38f }
        listOf("${s.episodes}" to episodesWord(s.episodes), "${s.activeDays}" to "дней с просмотром", "${s.completed.size}" to "завершено").forEachIndexed { i, (v, t) ->
            c.drawText(v, 80f + i * 330f, 760f, big); c.drawText(t, 80f + i * 330f, 815f, small)
        }
        val medium = Paint(white).apply { textSize = 52f }
        s.mostWatched?.let { c.drawText("Больше всего: $it".take(34), 80f, 950f, medium) }
        if (s.topRated.isNotEmpty()) c.drawText(("★★★★★ " + s.topRated.take(2).joinToString(" · ")).take(36), 80f, 1040f, Paint(medium).apply { color = 0xFFFFD60A.toInt() })
        c.drawText("Посчитано по отметкам в АниПолке", 80f, 1250f, small)
        File(context.cacheDir, "shared").apply { mkdirs() }.let { dir -> File(dir, "anipolka-${s.year}.png").also { f -> f.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) } } }
    }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "АниПолка ${s.year}"))
}

@Composable
fun ReportScreen() {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    var options by remember { mutableStateOf(ReportOptions()) }
    var copied by remember { mutableStateOf(false) }
    val text = remember(snapshot, options) { ShelfReport.text(snapshot, options) }
    LaunchedEffect(copied) { if (copied) { delay(2500); copied = false } }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Текст для копирования", navigator::pop)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            SectionTitle("Формат")
            Card {
                SingleChoiceRow(ReportOptions.Style.entries.map { it.label }, options.style.ordinal) { options = options.copy(style = ReportOptions.Style.entries[it]) }
                Spacer(Modifier.height(8.dp))
                Footnote(when (options.style) {
                    ReportOptions.Style.BRIEF -> "Одна строка на историю: название и серия, на которой вы остановились."
                    ReportOptions.Style.DETAILED -> "Статус, серия, источники и «+N», оценка, метки, дни выхода, где остановились, последний просмотр."
                    ReportOptions.Style.FOR_AI -> "То же, что «Подробно», плюс короткое пояснение для ИИ в начале и строка «Мой вопрос:» в конце."
                })
            }
            SectionTitle("Что включить")
            Card {
                WatchStatus.entries.forEach { s ->
                    SwitchRow("${s.raw} · ${snapshot.entries.count { it.status == s }}", s in options.statuses, { on -> options = options.copy(statuses = if (on) options.statuses + s else options.statuses - s) })
                }
                SwitchRow("Итоги и статистика", options.statistics, { options = options.copy(statistics = it) })
                SwitchRow("Заметки и «где остановился»", options.notes, { options = options.copy(notes = it) }, enabled = options.style != ReportOptions.Style.BRIEF)
                SwitchRow("Ссылки", options.links, { options = options.copy(links = it) }, enabled = options.style != ReportOptions.Style.BRIEF)
                Footnote("Итоги считаются по всей коллекции. Ссылки по умолчанию выключены: в них могут быть личные плейлисты.")
            }
            SectionTitle("Предпросмотр")
            Card { Text(text.take(6000) + if (text.length > 6000) "\n…" else "", fontFamily = FontFamily.Monospace, fontSize = 13.sp) }
            Footnote(if (text.length > 6000) "Предпросмотр сокращён, копируется весь текст (${text.length} символов)." else "${text.length} символов.", Modifier.padding(6.dp))
            Spacer(Modifier.height(8.dp))
            Button({
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("АниПолка", text)); copied = true
            }, Modifier.fillMaxWidth().height(48.dp)) { Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy, null); Spacer(Modifier.width(8.dp)); Text(if (copied) "Скопировано" else "Скопировать всё") }
            IosTintedButton({ context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "Мой список АниПолки")) },
                Modifier.fillMaxWidth().padding(top = 8.dp)) { Icon(Icons.Filled.Share, null); Spacer(Modifier.width(8.dp)); Text("Поделиться текстом") }
            Footnote("Для голосового чата с ИИ: выберите «Для ИИ», нажмите «Скопировать всё», вставьте текст в диалог и после этого включите голосовой режим.", Modifier.padding(6.dp))
        }
    }
}

@Composable
fun TitleHistoryScreen(id: UUID) {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    val marks = remember(snapshot) { WatchHistory.marks(id, snapshot) }
    val weeks = remember(marks) { WatchHistory.weekly(marks, 12) }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("История просмотра", navigator::pop)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            SectionTitle("Последние 12 недель")
            Card {
                val max = (weeks.maxOfOrNull { it.episodes } ?: 0).coerceAtLeast(1)
                Canvas(Modifier.fillMaxWidth().height(160.dp)) {
                    val slot = size.width / weeks.size.coerceAtLeast(1)
                    weeks.forEachIndexed { i, w ->
                        val h = size.height * w.episodes / max
                        drawRoundRect(Accent, Offset(i * slot + slot * 0.15f, size.height - h), Size(slot * 0.7f, h), CornerRadius(6f, 6f))
                    }
                }
                Footnote("Всего за 12 недель: ${weeks.sumOf { it.episodes }}")
            }
            SectionTitle("Отметки")
            Card {
                if (marks.isEmpty()) Footnote("Отметок пока нет. Они появляются после «+1» или изменения номера серии.")
                marks.take(300).forEach { m -> Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    Text("+${m.episodes} ${episodesWord(m.episodes)}", Modifier.weight(1f)); Text(formatDateTime(m.at), color = LocalShelfColors.current.secondaryText)
                } }
            }
        }
    }
}

@Composable
fun TextImportScreen() {
    val store = rememberStore()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var rows by remember { mutableStateOf<List<ImportRow>?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val pick = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            text = withContext(Dispatchers.IO) { runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() }?.takeIf { it.size <= 1_000_000 }?.toString(Charsets.UTF_8) }.getOrNull() } ?: run { message = "Файл больше 1 МБ или не в UTF-8."; text }
        }
    }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar(if (rows == null) "Перенос списка" else "Проверка списка", { if (rows != null) rows = null else navigator.pop() })
        val current = rows
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp).imePadding()) {
            if (current == null) {
                Card {
                    Footnote("Одна история на строку: название, пробел и последняя просмотренная серия. Например: «Путь к вершине 24». Названия с опечатками сохраняются как написаны.")
                    IosTextField(text, { text = it }, Modifier.fillMaxWidth().heightIn(min = 240.dp))
                    NavRow("Открыть текстовый файл", Icons.Filled.FileOpen) { pick.launch(arrayOf("text/*")) }
                    Button({
                        if (text.toByteArray().size > 1_000_000) { message = "Список больше 1 МБ."; return@Button }
                        val parsed = TextListParser.parse(text)
                        if (parsed.size > 2000) { message = "За один раз можно перенести не более 2000 записей."; return@Button }
                        // Any known name counts: «Swallowed Star 30» is the same work as «Пожиратель звёзд».
                        rows = parsed.map { r -> TitleMatcher.existing(r.title, store.current.entries)?.let { r.copy(duplicateOf = it.title, included = false) } ?: r }
                    }, Modifier.fillMaxWidth(), enabled = text.isNotBlank()) { Text("Проверить список") }
                    message?.let { Footnote(it, color = Orange) }
                    Footnote("Текст обрабатывается на устройстве. Ничего не отправляется в каталог.")
                }
            } else {
                Footnote("Проверьте названия и номера. Нераспознанные строки сохраняют исходное название с серией 0. Истории, которые уже есть в коллекции под этим или другим известным названием, по умолчанию не выбраны.", Modifier.padding(6.dp))
                current.forEachIndexed { i, row ->
                    Card(Modifier.padding(vertical = 5.dp)) {
                        SwitchRow("Добавить запись", row.included, { v -> rows = current.toMutableList().also { it[i] = row.copy(included = v) } })
                        IosTextField(row.title, { v -> rows = current.toMutableList().also { it[i] = row.copy(title = v) } }, Modifier.fillMaxWidth(), label = { Text("Название") })
                        IosTextField(row.episode.toString(), { v -> rows = current.toMutableList().also { it[i] = row.copy(episode = v.filter(Char::isDigit).take(7).toIntOrNull() ?: 0) } },
                            Modifier.fillMaxWidth(), label = { Text("Последняя серия") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                        SwitchRow("Избранное", row.favorite, { v -> rows = current.toMutableList().also { it[i] = row.copy(favorite = v) } })
                        if (!row.recognized) Footnote("⚠ Номер не распознан — проверьте", color = Orange)
                        row.duplicateOf?.let { Footnote("Уже есть в коллекции: «$it»", color = Accent) }
                        Footnote("Исходная строка: ${row.original}")
                    }
                }
                Button({ if (store.change { s -> s.copy(entries = s.entries + current.filter { it.included }.map { it.entry }) }) navigator.pop() },
                    Modifier.fillMaxWidth().padding(top = 8.dp), enabled = current.any { it.included }) { Text("Добавить выбранные: ${current.count { it.included }}") }
            }
        }
    }
}

@Composable
fun ReorderScreen() {
    val store = rememberStore()
    val navigator = LocalNavigator.current
    var ordered by remember { mutableStateOf(store.current.entries) }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Порядок на полке", navigator::pop) {
            GlassTextButton("Готово", { if (store.change { it.reordered(ordered.map { e -> e.id }).copy(preferences = it.preferences.copy(sort = ShelfSort.MANUAL)) }) navigator.pop() }, prominent = true)
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            Footnote("Стрелками меняйте порядок. Он сохранится для сортировки «Вручную».", Modifier.padding(6.dp))
            Card {
                ordered.forEachIndexed { i, e ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(e.title, Modifier.weight(1f))
                        IconButton({ ordered = ordered.toMutableList().also { java.util.Collections.swap(it, i, i - 1) } }, enabled = i > 0) { Icon(Icons.Filled.KeyboardArrowUp, "Выше") }
                        IconButton({ ordered = ordered.toMutableList().also { java.util.Collections.swap(it, i, i + 1) } }, enabled = i < ordered.lastIndex) { Icon(Icons.Filled.KeyboardArrowDown, "Ниже") }
                    }
                }
            }
        }
    }
}

@Composable
fun SuggestionScreen() {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    var current by remember { mutableStateOf(WatchSuggestion.pick(snapshot.entries)?.id) }
    val pool = WatchSuggestion.pool(snapshot.entries)
    val id = current
    if (id == null || snapshot.entry(id) == null) {
        Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
            ScreenTopBar("Что посмотреть?", navigator::pop)
            Card(Modifier.padding(16.dp)) { Text("Нечего предложить", fontWeight = FontWeight.Bold); Footnote("Здесь появятся истории «На потом» и те, у которых в источнике есть новые серии.") }
        }
        return
    }
    Box(Modifier.fillMaxSize()) {
        EntryDetailScreen(id)
        if (pool.size > 1) ExtendedFloatingActionButton(text = { Text("Другое") }, icon = { Icon(Icons.Filled.Casino, null) },
            onClick = { current = WatchSuggestion.pick(snapshot.entries, id)?.id }, modifier = Modifier.align(Alignment.BottomEnd).padding(24.dp).navigationBarsPadding(), containerColor = Accent)
    }
}

@Composable
fun LinkInboxScreen(url: String) {
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    var query by remember { mutableStateOf("") }
    var saved by remember { mutableStateOf<String?>(null) }
    val page = AnivibeCatalog.pages(listOf(url)).firstOrNull()
    val all = snapshot.visible(query)
    val entries = page?.let { p -> val likely = all.filter { TitleMatcher.matches(listOf(p.slugName), it) }; likely + all.filter { e -> likely.none { it.id == e.id } } } ?: all
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Добавить ссылку", { store.pendingLink.value = null; navigator.pop() })
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            Card {
                Text(url, fontSize = 13.sp)
                saved?.let { Footnote("✓ $it", color = Success) }
                Footnote("Выберите историю. Ссылку можно сохранить как страницу просмотра, а страницу AniVibe — подключить как источник новых серий.")
            }
            Spacer(Modifier.height(10.dp))
            SearchField(query, { query = it }, "Найти историю")
            Spacer(Modifier.height(10.dp))
            entries.forEach { e ->
                Card(Modifier.padding(vertical = 4.dp)) {
                    Text(e.title, fontWeight = FontWeight.SemiBold); Footnote(e.subtitle)
                    Row {
                        TextButton({ if (store.change { s -> s.withEntry(e.id) { it.copy(watchURL = url) } }) saved = "Ссылка сохранена в «${e.title}»." }) { Text("Ссылка просмотра") }
                        if (AnivibePageParser.canonicalURL(url) != null) TextButton({ navigator.push(Route.Sources(e.id, url)) }) { Text("Источник AniVibe") }
                    }
                }
            }
        }
    }
}
