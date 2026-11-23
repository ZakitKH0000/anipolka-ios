package com.zakitkh.anipolka.ui

import android.app.DatePickerDialog
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.NetworkService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

@Composable
fun EntryEditorScreen(id: UUID) {
    val store = rememberStore()
    val network = rememberNetwork()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val original = remember { store.current.entry(id) }
    if (original == null) { LaunchedEffect(Unit) { navigator.pop() }; return }
    var entry by remember { mutableStateOf(original) }
    var tagsText by remember { mutableStateOf(original.tags.joinToString(", ")) }
    var aliasesText by remember { mutableStateOf(original.aliases.joinToString("\n")) }
    var episodeText by remember { mutableStateOf(original.episode.toString()) }
    var related by remember { mutableStateOf(Relations.related(original, store.current.entries).map { it.id }.toSet()) }
    var coverChanged by remember { mutableStateOf(false) }
    var searching by remember { mutableStateOf(false) }
    var pickingRelated by remember { mutableStateOf(false) }
    var alternatives by remember { mutableStateOf<List<String>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            busy = true
            val data = withContext(Dispatchers.IO) { runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull() }
            val normalized = data?.let { withContext(Dispatchers.Default) { NetworkService.normalized(it) } }
            if (normalized == null) problem = "Не удалось открыть изображение. Выберите файл до 20 МБ."
            else { entry = entry.copy(coverData = Blob(normalized), coverURL = "", coverDiscovery = null); coverChanged = true }
            busy = false
        }
    }

    fun save() {
        var e = entry.copy(title = entry.title.trim(), watchURL = entry.watchURL.trim(), episode = episodeText.toIntOrNull()?.coerceIn(0, 1_000_000) ?: 0)
        if (e.title.isEmpty()) { problem = "Введите название."; return }
        if (e.watchURL.isNotEmpty() && validWebURL(e.watchURL) == null) { problem = "Ссылка должна начинаться с http:// или https:// и содержать адрес сайта."; return }
        e = e.copy(tags = Tags.parse(tagsText), aliases = Aliases.merge(emptyList(), Aliases.parse(aliasesText), listOf(e.title)))
        val old = store.current.entry(id)
        if (old != null) {
            if (old.episode != e.episode) e = e.copy(watchedAt = Instant.now())
            // Background covers and source checks may have finished while the editor was open.
            e = e.copy(subscriptions = old.subscriptions, releaseNotices = old.releaseNotices)
            if (!coverChanged && e.coverLookupDisabled != true && e.coverURL.isEmpty() && e.coverData == null && old.coverURL.isNotEmpty())
                e = e.copy(coverURL = old.coverURL, coverData = old.coverData, sourceID = old.sourceID, sourceURL = old.sourceURL, originalTitle = old.originalTitle, coverDiscovery = old.coverDiscovery)
            if (e.coverData == null && e.coverURL.isNotEmpty() && e.coverURL == old.coverURL) e = e.copy(coverData = old.coverData)
        }
        e = e.copy(updatedAt = Instant.now())
        // Links work both ways, so a removed link is also removed from the other title.
        val before = Relations.related(old ?: e, store.current.entries).map { it.id }.toSet()
        val removed = before - related
        e = e.copy(relatedIDs = related.take(Relations.LIMIT))
        val toSave = e
        if (store.change { s -> removed.fold(s.save(toSave)) { acc, other -> Relations.unlink(toSave.id, other, acc) } }) navigator.pop()
    }

    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Редактирование", navigator::pop) { GlassTextButton("Сохранить", ::save, enabled = !busy, prominent = true) }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 40.dp).imePadding()) {
            SectionTitle("Название и прогресс")
            Card {
                IosTextField(entry.title, { entry = entry.copy(title = it.take(500)) }, Modifier.fillMaxWidth(), label = { Text("Привычное название") })
                Spacer(Modifier.height(8.dp))
                IosTextField(episodeText, { episodeText = it.filter(Char::isDigit).take(7) }, Modifier.fillMaxWidth(), label = { Text("Последняя серия") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                SwitchRow("Указывать сезон", entry.season != null, { entry = entry.copy(season = if (it) entry.season ?: 1 else null) })
                entry.season?.let { season ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Сезон $season", Modifier.weight(1f))
                        IconButton({ entry = entry.copy(season = maxOf(1, season - 1)) }) { Icon(Icons.Filled.Remove, "Меньше") }
                        IconButton({ entry = entry.copy(season = minOf(10000, season + 1)) }) { Icon(Icons.Filled.Add, "Больше") }
                    }
                }
                Text("Статус", color = LocalShelfColors.current.secondaryText)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    WatchStatus.entries.forEach { s -> FilterChipPill(s.raw, entry.status == s, { entry = entry.copy(status = s) }) }
                }
                SwitchRow("Избранное", entry.favorite, { entry = entry.copy(favorite = it) })
                Row(verticalAlignment = Alignment.CenterVertically) { Text("Моя оценка", Modifier.weight(1f)); RatingStars(entry.rating, { entry = entry.copy(rating = it) }, 26.dp) }
            }
            SectionTitle("Дни выхода и метки")
            Card {
                WeekdayPicker(entry.releaseDays) { entry = entry.copy(releaseDays = it) }
                Spacer(Modifier.height(10.dp))
                IosTextField(tagsText, { tagsText = it }, Modifier.fillMaxWidth(), label = { Text("Метки через запятую: дунхуа, с другом") })
                SwitchRow("Дата премьеры", entry.premiereDate != null, { on ->
                    entry = entry.copy(premiereDate = if (on) entry.premiereDate ?: LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant() else null)
                })
                entry.premiereDate?.let { premiere ->
                    NavRow("Премьера", Icons.Filled.Event, formatDate(premiere)) {
                        val d = premiere.atZone(ZoneId.systemDefault()).toLocalDate()
                        DatePickerDialog(context, { _, y, m, day -> entry = entry.copy(premiereDate = LocalDate.of(y, m + 1, day).atStartOfDay(ZoneId.systemDefault()).toInstant()) }, d.year, d.monthValue - 1, d.dayOfMonth).show()
                    }
                }
                NavRow("Связанные части", Icons.Filled.Link, if (related.isEmpty()) "нет" else "${related.size}") { pickingRelated = true }
                Footnote("Дни выхода указываете вы сами: приложение их не угадывает. В эти дни сводка напомнит о новых сериях, если её включить в Настройках. В день премьеры в 10:00 придёт одно напоминание.")
            }
            SectionTitle("Обложка")
            Card {
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CoverImage(entry.coverData, entry.coverURL, Modifier.size(140.dp, 185.dp).clip(RoundedCornerShape(16.dp)), maxSide = 600)
                }
                NavRow("Найти произведение / сменить обложку", Icons.Filled.Search) { searching = true }
                NavRow("Своя обложка из галереи", Icons.Filled.Image) { photo.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                entry.sourceID?.let { source ->
                    NavRow("Другие изображения этого произведения", Icons.Filled.Collections) {
                        scope.launch {
                            busy = true
                            runCatching { network.alternatives(source) }.onSuccess { alternatives = it; if (it.isEmpty()) problem = "Для этого произведения других изображений нет." }
                                .onFailure { problem = it.message }
                            busy = false
                        }
                    }
                }
                if (alternatives.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    alternatives.forEach { url ->
                        CoverImage(null, url, Modifier.size(120.dp, 90.dp).clip(RoundedCornerShape(10.dp)).clickable {
                            entry = entry.copy(coverURL = url, coverData = null, coverDiscovery = null, coverLookupDisabled = false); coverChanged = true; alternatives = emptyList()
                        }, maxSide = 400)
                    }
                }
                if (entry.coverURL.isNotEmpty() || entry.coverData != null) NavRow("Убрать обложку", Icons.Filled.Delete, color = Danger) {
                    entry = entry.copy(coverURL = "", coverData = null, coverDiscovery = null, coverLookupDisabled = true); coverChanged = true
                }
                SwitchRow("Искать обложку автоматически", entry.coverLookupDisabled != true, { on -> entry = entry.copy(coverLookupDisabled = !on, coverDiscovery = if (on) null else entry.coverDiscovery) })
            }
            SectionTitle("Другие названия")
            Card {
                IosTextField(aliasesText, { aliasesText = it }, Modifier.fillMaxWidth(), label = { Text("Каждое название с новой строки") }, minLines = 2)
                Footnote("Английские, оригинальные и ваши варианты. По ним работают поиск в коллекции, проверка дублей при импорте и подбор страницы AniVibe.")
            }
            SectionTitle("Заметка и ссылка")
            Card {
                IosTextField(entry.note, { entry = entry.copy(note = it.take(20000)) }, Modifier.fillMaxWidth(), label = { Text("Заметка") }, minLines = 3)
                Spacer(Modifier.height(8.dp))
                IosTextField(entry.watchURL, { entry = entry.copy(watchURL = it) }, Modifier.fillMaxWidth(), label = { Text("https://… — страница просмотра") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            }
            if (entry.originalTitle.isNotEmpty()) {
                SectionTitle("Из каталога")
                Card { Text(entry.originalTitle); Footnote("Сезон и прогресс не определяются автоматически. Можно вести сквозную нумерацию.") }
            }
        }
    }
    if (searching) Dialog({ searching = false }, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
            ScreenTopBar("Найти обложку", { searching = false })
            val search = remember { WizardSearch(scope) }
            LaunchedEffect(Unit) { search.query = entry.title }
            CatalogSearchPanel(search, store.current.entries, { c ->
                entry = entry.copy(originalTitle = c.name, sourceID = c.shikimoriID, sourceURL = c.pageURL, coverURL = c.posterURL, coverData = null, coverLookupDisabled = false, coverDiscovery = null)
                aliasesText = Aliases.merge(Aliases.parse(aliasesText), c.names, listOf(entry.title)).joinToString("\n")
                coverChanged = true; alternatives = emptyList(); searching = false
            }, null, "Выбрать произведение и обложку")
        }
    }
    if (pickingRelated) RelatedPickerDialog(id, related, { related = it }) { pickingRelated = false }
    problem?.let { AlertDialog({ problem = null }, confirmButton = { TextButton({ problem = null }) { Text("Понятно") } }, title = { Text("Проверьте данные") }, text = { Text(it) }) }
}

@Composable
private fun RelatedPickerDialog(entryID: UUID, selected: Set<UUID>, onChange: (Set<UUID>) -> Unit, onClose: () -> Unit) {
    val snapshot = rememberSnapshot()
    var query by remember { mutableStateOf("") }
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
            ScreenTopBar("Связанные части", onClose) { GlassTextButton("Готово", onClose, prominent = true) }
            Box(Modifier.padding(horizontal = 16.dp)) { SearchField(query, { query = it }, "Найти историю") }
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
                snapshot.visible(query).filter { it.id != entryID }.forEach { other ->
                    val on = other.id in selected
                    Row(Modifier.fillMaxWidth().clickable {
                        onChange(if (on) selected - other.id else if (selected.size < Relations.LIMIT) selected + other.id else selected)
                    }.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { Text(other.title); Footnote(other.subtitle) }
                        if (on) Icon(Icons.Filled.Check, "Выбрано", tint = Accent)
                    }
                }
            }
        }
    }
}
