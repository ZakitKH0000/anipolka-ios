package com.zakitkh.anipolka.ui

import androidx.compose.ui.platform.LocalDensity
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

private val dateTime = DateTimeFormatter.ofPattern("d MMM yyyy, HH:mm", Locale("ru")).withZone(ZoneId.systemDefault())
private val dateOnly = DateTimeFormatter.ofPattern("d MMM yyyy", Locale("ru")).withZone(ZoneId.systemDefault())
fun formatDateTime(i: Instant): String = dateTime.format(i)
fun formatDate(i: Instant): String = dateOnly.format(i)

/** Average cover colour, brightened enough to work as an accent. */
object CoverPalette {
    private val cache = HashMap<Int, Color>()
    fun accent(data: Blob?): Color? {
        data ?: return null
        val key = data.hashCode()
        cache[key]?.let { return it }
        val bitmap = BitmapFactory.decodeByteArray(data.bytes, 0, data.size, BitmapFactory.Options().apply { inSampleSize = 16 }) ?: return null
        val pixel = android.graphics.Bitmap.createScaledBitmap(bitmap, 1, 1, true).getPixel(0, 0)
        val hsv = FloatArray(3); android.graphics.Color.colorToHSV(pixel, hsv)
        hsv[1] = hsv[1].coerceIn(0.45f, 0.85f); hsv[2] = hsv[2].coerceIn(0.7f, 0.9f)
        return Color(android.graphics.Color.HSVToColor(hsv)).also { cache[key] = it }
    }
}

fun openUrl(context: android.content.Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}

fun validWebURL(text: String): String? {
    val uri = runCatching { java.net.URI(text.trim()) }.getOrNull() ?: return null
    return if ((uri.scheme?.lowercase() == "http" || uri.scheme?.lowercase() == "https") && uri.host != null) text.trim() else null
}

@Composable
fun EntryDetailScreen(id: UUID) {
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val colors = LocalShelfColors.current
    val e = snapshot.entry(id)
    if (e == null) {
        Column(Modifier.fillMaxSize()) { ScreenTopBar("", navigator::pop); Text("Запись удалена", Modifier.padding(24.dp)) }
        return
    }
    val accent = remember(e.coverData) { CoverPalette.accent(e.coverData) } ?: Accent
    var deleteConfirm by remember { mutableStateOf(false) }
    var rewatchConfirm by remember { mutableStateOf(false) }
    var showAliases by remember { mutableStateOf(false) }
    val scroll = rememberScrollState()
    val haze = rememberHazeState()
    val density = LocalDensity.current
    val collapsed by remember { derivedStateOf { scroll.value > with(density) { 380.dp.roundToPx() } } }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().hazeSource(haze)) {
        // Blurred cover behind the content, fading into the background.
        if (e.coverData != null && Build.VERSION.SDK_INT >= 31) {
            CoverImage(e.coverData, e.coverURL, Modifier.fillMaxWidth().height(520.dp).blur(60.dp).alpha(0.5f), maxSide = 300)
            Box(Modifier.fillMaxWidth().height(520.dp).background(Brush.verticalGradient(listOf(Color.Transparent, colors.background))))
        }
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.verticalScroll(scroll).padding(horizontal = 20.dp).padding(top = contentTopPadding(), bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                CoverImage(e.coverData, e.coverURL, Modifier.fillMaxWidth().height(330.dp).clip(RoundedCornerShape(24.dp)), e.id, 48.dp, 1200)
                Column {
                    Text(e.title, fontSize = 32.sp, fontWeight = FontWeight.Bold, lineHeight = 36.sp)
                    if (e.originalTitle.isNotEmpty() && e.originalTitle != e.title) Text(e.originalTitle, color = colors.secondaryText)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Последняя просмотренная", color = colors.secondaryText, fontSize = 14.sp)
                        Text("Серия ${e.episode}", fontSize = 28.sp, fontWeight = FontWeight.Bold)
                        e.season?.let { Text("Сезон $it") }
                        e.passTitle?.let { Footnote(it) }
                    }
                    IncrementButton(e)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.BookmarkBorder, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(e.status.raw, fontSize = 15.sp)
                    Spacer(Modifier.weight(1f))
                    TextButton({ store.save(e.copy(favorite = !e.favorite, updatedAt = Instant.now())) }) {
                        Icon(if (e.favorite) Icons.Filled.Star else Icons.Outlined.StarBorder, null, tint = if (e.favorite) Gold else accent)
                        Spacer(Modifier.width(4.dp)); Text(if (e.favorite) "В избранном" else "В избранное", color = accent)
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RatingStars(e.rating, { store.save(e.copy(rating = it, updatedAt = Instant.now())) })
                    Spacer(Modifier.weight(1f))
                    e.completedAt?.let { Footnote("Завершено ${formatDate(it)}") }
                }
                Backlog.available(e)?.let { Text("▶ Доступно ещё $it ${episodesWord(it)} в источнике", color = accent, fontWeight = FontWeight.Bold) }
                e.premiereDate?.let { if (PremierePlanner.upcoming(listOf(e)).isNotEmpty()) Text("✦ " + PremierePlanner.label(it), color = Orange, fontWeight = FontWeight.Bold) }
                if (e.releaseDays.isNotEmpty()) Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.CalendarMonth, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Выходит: ${ReleasePlanner.days(e)}")
                }
                if (e.tags.isNotEmpty()) TagChips(e.tags)
                if (Backlog.caughtUp(e)) Footnote("⌛ Догнал: жду новые серии")
                if (e.aliases.isNotEmpty()) {
                    Text("Другие названия: ${e.aliases.size} " + if (showAliases) "▲" else "▼", Modifier.clickable { showAliases = !showAliases }, color = accent)
                    if (showAliases) Column { e.aliases.forEach { Text(it, fontSize = 15.sp) } }
                }
                AiringCard(e, accent)
                Airing.sequelSuggestion(e, snapshot)?.let { hint ->
                    Card(padding = 0.dp) {
                        SequelRow(e, hint, onAdd = { addSequel(store, e.id, hint) },
                            onHide = { store.change { s -> s.withEntry(e.id) { it.copy(dismissedSequelID = hint.id) } } })
                    }
                }
                ResumeCard(e)
                WatchLinksCard(e)
                RelatedCard(e)
                IosGroup(Modifier.padding(top = 0.dp), inset = 60.dp, spaced = false) {
                    IosRow("История просмотра", icon = Icons.Filled.History, iconTint = accent, chevron = true, onClick = { navigator.push(Route.History(e.id)) })
                    IosRow("Источники новых серий", icon = Icons.Filled.NotificationsActive, iconTint = accent, chevron = true, onClick = { navigator.push(Route.Sources(e.id)) })
                }
                e.coverDiscovery?.let { d ->
                    Footnote(d.message)
                    if (d.needsChoice) TextButton({ navigator.push(Route.Editor(id)) }) { Text("Выбрать обложку") }
                }
                e.subscriptions.forEach { s ->
                    Column {
                        Text(s.label, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                        s.lastEpisode?.let { Footnote("В источнике доступна серия $it") }
                        s.error?.let { Footnote(it, color = Orange) }
                    }
                }
                if (e.note.isNotEmpty()) Column { Text("Заметка", fontWeight = FontWeight.Bold); Text(e.note) }
                validWebURL(e.watchURL)?.let { url ->
                    Button({ openUrl(context, url) }, Modifier.fillMaxWidth().height(54.dp), shape = androidx.compose.foundation.shape.CircleShape, colors = ButtonDefaults.buttonColors(containerColor = accent)) {
                        Icon(Icons.Filled.PlayCircle, null); Spacer(Modifier.width(8.dp)); Text("Открыть страницу просмотра")
                    }
                }
                IosGroup(inset = 60.dp, spaced = false) {
                    validWebURL(e.sourceURL)?.let { url ->
                        IosRow("Карточка произведения: ${if (url.contains("kitsu")) "Kitsu" else "Shikimori"}", icon = Icons.Filled.OpenInNew, iconTint = accent, titleColor = accent, onClick = { openUrl(context, url) })
                    }
                    if (e.episode > 0 || e.status == WatchStatus.COMPLETED)
                        IosRow("Начать пересмотр", icon = Icons.Filled.Replay, iconTint = accent, titleColor = accent, onClick = { rewatchConfirm = true })
                    IosRow("Удалить из коллекции", icon = Icons.Filled.Delete, iconTint = Danger, titleColor = Danger, onClick = { deleteConfirm = true })
                }
            }
        }
        }
        GlassTopBar(e.title, collapsed, haze, onBack = navigator::pop) {
            GlassTextButton("Изменить", { navigator.push(Route.Editor(id)) }, color = accent)
        }
    }
    if (deleteConfirm) AlertDialog({ deleteConfirm = false },
        title = { Text("Удалить «${e.title}» и прогресс?") }, text = { Text("Вернуть запись можно из заранее сохранённой резервной копии.") },
        confirmButton = { TextButton({ deleteConfirm = false; if (store.change { s -> s.copy(entries = s.entries.filter { it.id != id }) }) navigator.pop() }) { Text("Удалить запись", color = Danger) } },
        dismissButton = { TextButton({ deleteConfirm = false }) { Text("Отмена") } })
    if (rewatchConfirm) AlertDialog({ rewatchConfirm = false },
        title = { Text("Начать «${e.title}» заново?") }, text = { Text("Номер серии станет 0, статус — «Смотрю». Сколько серий было в прошлый раз, сохранится в карточке.") },
        confirmButton = { TextButton({ rewatchConfirm = false; store.save(e.startRewatch()) }) { Text("Начать пересмотр") } },
        dismissButton = { TextButton({ rewatchConfirm = false }) { Text("Отмена") } })
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ResumeCard(e: Entry) {
    val store = rememberStore()
    var editing by remember { mutableStateOf<EpisodeNote?>(null) }
    var menuFor by remember { mutableStateOf<EpisodeNote?>(null) }
    var showOlder by remember { mutableStateOf(false) }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Где остановился", Modifier.weight(1f), fontWeight = FontWeight.Bold)
            TextButton({ editing = EpisodeNote(episode = e.episode + 1) }) { Icon(Icons.Filled.BookmarkAdd, null); Spacer(Modifier.width(4.dp)); Text("Отметить") }
        }
        val point = e.resumePoint
        if (point == null) Footnote("Сохраните серию, минуту и заметку, например «серия 25 · 14:30 · смотрю в озвучке ПВА ШОУ».")
        else {
            Column(Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = { menuFor = point })) {
                Text("Серия ${point.episode}" + if (point.time.isEmpty()) "" else " · ${point.time}", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                if (point.text.isNotEmpty()) Text(point.text)
                Footnote(formatDateTime(point.createdAt))
            }
            val older = e.notes.filter { it.id != point.id }.sortedByDescending { it.createdAt }
            if (older.isNotEmpty()) {
                TextButton({ showOlder = !showOlder }) { Text("Другие заметки: ${older.size} " + if (showOlder) "▲" else "▼") }
                if (showOlder) older.forEach { note ->
                    Column(Modifier.fillMaxWidth().combinedClickable(onClick = {}, onLongClick = { menuFor = note }).padding(vertical = 4.dp)) {
                        Text("Серия ${note.episode}" + if (note.time.isEmpty()) "" else " · ${note.time}", fontWeight = FontWeight.SemiBold)
                        if (note.text.isNotEmpty()) Text(note.text, fontSize = 15.sp)
                    }
                }
            }
            Footnote("Удерживайте заметку, чтобы изменить или удалить.")
        }
    }
    menuFor?.let { note ->
        AlertDialog({ menuFor = null }, title = { Text("Заметка к серии ${note.episode}") },
            confirmButton = { TextButton({ menuFor = null; editing = note }) { Text("Изменить") } },
            dismissButton = { TextButton({ menuFor = null; store.change { s -> s.withEntry(e.id) { it.copy(notes = it.notes.filter { n -> n.id != note.id }) } } }) { Text("Удалить", color = Danger) } })
    }
    editing?.let { note -> NoteEditorDialog(e.id, note) { editing = null } }
}

@Composable
private fun NoteEditorDialog(entryID: UUID, initial: EpisodeNote, onClose: () -> Unit) {
    val store = rememberStore()
    var episode by remember { mutableStateOf(initial.episode.toString()) }
    var time by remember { mutableStateOf(initial.time) }
    var text by remember { mutableStateOf(initial.text) }
    var problem by remember { mutableStateOf<String?>(null) }
    AlertDialog(onClose, title = { Text("Где остановился") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                IosTextField(episode, { episode = it.filter(Char::isDigit).take(7) }, label = { Text("Серия") }, singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number))
                IosTextField(time, { time = it.take(10) }, label = { Text("Минута, например 14:30") }, singleLine = true)
                IosTextField(text, { text = it.take(2000) }, label = { Text("Заметка: озвучка, плейлист…") }, minLines = 2)
                Footnote("Последняя заметка показывается в карточке как «Где остановился».")
                problem?.let { Footnote(it, color = Orange) }
            }
        },
        confirmButton = {
            TextButton({
                val normalized = EpisodeTime.normalized(time)
                if (normalized == null) { problem = "Минуту укажите как 14:30 или 1:02:03."; return@TextButton }
                val note = initial.copy(episode = episode.toIntOrNull() ?: 0, time = normalized, text = text.trim())
                val saved = store.change { s -> s.withEntry(entryID) { en ->
                    if (en.notes.any { it.id == note.id }) en.copy(notes = en.notes.map { if (it.id == note.id) note else it })
                    else en.addNote(note.copy(createdAt = Instant.now()))
                } }
                if (saved) onClose()
            }) { Text("Сохранить") }
        },
        dismissButton = { TextButton(onClose) { Text("Отмена") } })
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WatchLinksCard(e: Entry) {
    val store = rememberStore()
    val context = LocalContext.current
    var adding by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<WatchLink?>(null) }
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Где смотрю", Modifier.weight(1f), fontWeight = FontWeight.Bold)
            TextButton({ adding = true }) { Icon(Icons.Filled.AddLink, null); Spacer(Modifier.width(4.dp)); Text("Добавить") }
        }
        if (e.links.isEmpty()) Footnote("Площадки, плейлисты и озвучки, где вы смотрите эту историю. Основная ссылка открывается кнопкой «Открыть страницу просмотра».")
        else {
            e.links.forEach { link ->
                Column(Modifier.fillMaxWidth().combinedClickable(onClick = { validWebURL(link.url)?.let { openUrl(context, it) } }, onLongClick = { menuFor = link }).padding(vertical = 6.dp)) {
                    Text(link.label, fontWeight = FontWeight.SemiBold)
                    Footnote(runCatching { java.net.URI(link.url).host }.getOrNull() ?: link.url)
                }
            }
            Footnote("Удерживайте ссылку, чтобы сделать её основной или удалить.")
        }
    }
    menuFor?.let { link ->
        AlertDialog({ menuFor = null }, title = { Text(link.label) },
            confirmButton = { TextButton({ menuFor = null; store.change { s -> s.withEntry(e.id) { it.promoteLink(link.id) } } }) { Text("Сделать основной") } },
            dismissButton = { TextButton({ menuFor = null; store.change { s -> s.withEntry(e.id) { it.copy(links = it.links.filter { l -> l.id != link.id }) } } }) { Text("Удалить", color = Danger) } })
    }
    if (adding) LinkEditorDialog(e.id) { adding = false }
}

@Composable
private fun LinkEditorDialog(entryID: UUID, onClose: () -> Unit) {
    val store = rememberStore()
    var label by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    var primary by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    AlertDialog(onClose, title = { Text("Где смотрю") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                IosTextField(label, { label = it.take(100) }, label = { Text("Название: AniVibe · ПВА ШОУ") })
                IosTextField(address, { address = it }, label = { Text("https://…") }, singleLine = true)
                SwitchRow("Сделать основной", primary, { primary = it })
                problem?.let { Footnote(it, color = Orange) }
            }
        },
        confirmButton = {
            TextButton({
                val url = address.trim()
                val parsed = validWebURL(url)
                if (parsed == null || url.length > 4000) { problem = "Ссылка должна начинаться с http:// или https://."; return@TextButton }
                val name = label.trim().ifEmpty { runCatching { java.net.URI(url).host }.getOrNull() ?: "Ссылка" }
                val saved = store.change { s -> s.withEntry(entryID) { en ->
                    if (en.links.size >= WatchLink.LIMIT) en else {
                        val link = WatchLink(label = name, url = url)
                        val next = en.copy(links = en.links + link)
                        if (primary) next.promoteLink(link.id) else next
                    }
                } }
                if (saved) onClose()
            }) { Text("Сохранить") }
        },
        dismissButton = { TextButton(onClose) { Text("Отмена") } })
}

@Composable
private fun RelatedCard(e: Entry) {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    val related = Relations.related(e, snapshot.entries)
    if (related.isEmpty()) return
    Card {
        Text("Связанные части", fontWeight = FontWeight.Bold)
        related.forEach { part ->
            Row(Modifier.fillMaxWidth().clickable { navigator.push(Route.Detail(part.id)) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                CoverImage(part.coverData, part.coverURL, Modifier.size(44.dp, 58.dp).clip(RoundedCornerShape(8.dp)), part.id, 18.dp, 200)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) { Text(part.title, fontWeight = FontWeight.SemiBold); Footnote(part.subtitle) }
                Icon(Icons.Filled.ChevronRight, null, tint = LocalShelfColors.current.secondaryText)
            }
        }
    }
}
