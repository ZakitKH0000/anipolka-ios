package com.zakitkh.anipolka.ui

import android.app.DatePickerDialog
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.NetworkService
import com.zakitkh.anipolka.data.Notifications
import com.zakitkh.anipolka.data.ShelfAssistant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Search state lives outside the step, so going back keeps the results. */
class WizardSearch(private val scope: CoroutineScope) {
    enum class Where(val label: String) { ALL("Везде"), SHIKIMORI("Shikimori"), KITSU("Kitsu") }
    var query by mutableStateOf("")
    var where by mutableStateOf(Where.ALL)
    var results by mutableStateOf<List<AnimeCandidate>>(emptyList()); private set
    var loading by mutableStateOf(false); private set
    var searched by mutableStateOf(false); private set
    var message by mutableStateOf<String?>(null); private set
    private var job: Job? = null

    fun reset() { job?.cancel(); loading = false; searched = false; results = emptyList(); message = null }

    fun run(network: NetworkService) {
        val term = query.trim(); if (term.isEmpty()) return
        job?.cancel(); loading = true; searched = true; message = null; results = emptyList()
        val where = where
        job = scope.launch {
            val merged = mutableListOf<AnimeCandidate>(); val failed = mutableListOf<String>()
            if (where != Where.KITSU) try { merged += network.search(term, AnimeCatalog.SHIKIMORI) } catch (e: CancellationException) { throw e } catch (e: Exception) { failed += "Shikimori" }
            if (where != Where.SHIKIMORI) try {
                // The same edition from both catalogues is listed once, Shikimori first.
                val found = network.search(term, AnimeCatalog.KITSU)
                merged += found.filter { c -> merged.none { it.sameEdition(c) } }
            } catch (e: CancellationException) { throw e } catch (e: Exception) { failed += "Kitsu" }
            results = merged; loading = false
            if (merged.isEmpty() && failed.isNotEmpty()) message = "Не удалось выполнить поиск: ${failed.joinToString(", ")} сейчас недоступен."
        }
    }
}

@Composable
fun CatalogSearchPanel(search: WizardSearch, existing: List<Entry>, onPick: (AnimeCandidate) -> Unit, onManual: ((String) -> Unit)?, pickLabel: String, header: (@Composable () -> Unit)? = null) {
    val network = rememberNetwork()
    val colors = LocalShelfColors.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    // Results appear below the field, so the keyboard is closed when a search starts.
    val runSearch = { focus.clearFocus(); search.run(network) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        header?.invoke()
        IosTextField(search.query, { search.query = it }, Modifier.fillMaxWidth(), singleLine = true, placeholder = { Text("Например: Tunshi Xingkong") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = { if (search.loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else if (search.query.isNotEmpty()) IconButton({ search.query = ""; search.reset() }) { Icon(Icons.Filled.Cancel, "Очистить") } },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { runSearch() }))
        SingleChoiceRow(WizardSearch.Where.entries.map { it.label }, search.where.ordinal) { search.where = WizardSearch.Where.entries[it] }
        Button({ runSearch() }, Modifier.fillMaxWidth().height(48.dp), enabled = search.query.isNotBlank() && !search.loading) { Text("Искать") }
        if (!network.canLoadCovers && network.wifiOnly) Footnote("Обложки загрузятся при подключении к Wi-Fi. Поиск названий доступен через любую сеть.")
        search.message?.let { Footnote(it) }
        if (search.searched && !search.loading && search.results.isEmpty() && search.message == null) Footnote("Совпадений нет. Попробуйте короткое или оригинальное название, другой каталог или добавьте вручную.")
        search.results.forEachIndexed { _, c ->
            val known = c.names.firstNotNullOfOrNull { TitleMatcher.existing(it, existing) }
            val catalog = if (c.catalog == AnimeCatalog.KITSU) "Kitsu" else "Shikimori"
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(colors.surface).clickable { onPick(c) }.padding(12.dp)
                .semantics(mergeDescendants = true) { contentDescription = "${c.title}. ${c.detail}. $catalog. $pickLabel" }) {
                CoverImage(null, c.previewURL, Modifier.size(68.dp, 96.dp).clip(RoundedCornerShape(12.dp)), maxSide = 300)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(c.title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                    Footnote(c.detail)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(catalog, Modifier.clip(CircleShape).background(colors.primaryText.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 2.dp), fontSize = 11.sp, fontWeight = FontWeight.Bold)
                        known?.let { Spacer(Modifier.width(6.dp)); Text("Уже есть: ${it.title}", color = Orange, fontSize = 12.sp, maxLines = 1) }
                    }
                }
                Icon(Icons.Filled.ChevronRight, null, tint = colors.secondaryText)
            }
        }
        if (onManual != null) {
            HorizontalDivider()
            IosTintedButton({ onManual(search.query) }, Modifier.fillMaxWidth().height(48.dp)) { Icon(Icons.Filled.EditNote, null); Spacer(Modifier.width(6.dp)); Text("Добавить вручную") }
            Footnote("Вручную можно ввести привычное название и сквозной номер серии. Обложка подберётся сама или её можно выбрать позже. Каталоги содержат не все дунхуа и варианты перевода.")
        }
    }
}

@Composable
fun SingleChoiceRow(labels: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    val colors = LocalShelfColors.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.surfaceHigh).padding(3.dp)) {
        labels.forEachIndexed { i, label ->
            Box(Modifier.weight(1f).height(36.dp).clip(RoundedCornerShape(10.dp)).background(if (i == selected) colors.surface else colors.surfaceHigh).clickable { onSelect(i) },
                contentAlignment = Alignment.Center) { Text(label, fontWeight = if (i == selected) FontWeight.SemiBold else FontWeight.Normal, fontSize = 14.sp) }
        }
    }
}

private enum class Step(val title: String) { FIND("Найти"), PROGRESS("Прогресс"), SOURCE("Где смотрю"), FINISH("Готово") }

@Composable
fun AddWizardScreen() {
    val store = rememberStore()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val search = remember { WizardSearch(scope) }
    var step by remember { mutableStateOf(Step.FIND) }
    var draft by remember { mutableStateOf(Entry(title = "")) }
    var picked by remember { mutableStateOf<AnimeCandidate?>(null) }
    var confirmClose by remember { mutableStateOf(false) }
    var confirmDuplicate by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val started = step != Step.FIND || search.query.isNotEmpty()
    val duplicate = (listOf(draft.title, draft.originalTitle) + draft.aliases).firstNotNullOfOrNull { TitleMatcher.existing(it, store.current.entries) }
    val hasSource = draft.subscriptions.isNotEmpty() || draft.watchURL.isNotBlank()

    fun go(next: Step) { step = next }
    fun back() { if (step.ordinal > 0) go(Step.entries[step.ordinal - 1]) else if (started) confirmClose = true else navigator.pop() }
    fun save() {
        var e = draft.copy(title = draft.title.trim(), watchURL = draft.watchURL.trim())
        if (e.title.isEmpty()) { problem = "Введите название."; go(Step.PROGRESS); return }
        if (e.watchURL.isNotEmpty() && validWebURL(e.watchURL) == null) { problem = "Ссылка для просмотра должна начинаться с http:// или https:// и содержать адрес сайта."; go(Step.SOURCE); return }
        val now = Instant.now()
        e = e.copy(updatedAt = now, watchedAt = if (e.episode > 0) now else null)
        if (store.save(e)) {
            if (e.premiereDate != null && !Notifications.allowed(context)) problem = null
            navigator.pop()
        } else { problem = store.error.value ?: "Не удалось сохранить."; store.error.value = null }
    }
    BackHandler { back() }

    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        Column(Modifier.statusBarsPadding().padding(top = 4.dp, bottom = 8.dp)) {
            Row(Modifier.fillMaxWidth().height(TopBarHeight).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                GlassIconButton(Icons.Filled.Close, "Закрыть", { if (started) confirmClose = true else navigator.pop() })
                Text("Шаг ${step.ordinal + 1} из 4 · ${step.title}", Modifier.weight(1f), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Spacer(Modifier.width(46.dp))
            }
            Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Step.entries.forEach { s -> Box(Modifier.weight(1f).height(4.dp).clip(CircleShape).background(if (s.ordinal <= step.ordinal) Accent else LocalShelfColors.current.secondaryText.copy(alpha = 0.3f))) }
            }
        }
        Box(Modifier.weight(1f)) {
            when (step) {
                Step.FIND -> CatalogSearchPanel(search, store.current.entries, { c ->
                    draft = Entry(title = c.title, originalTitle = c.name, sourceID = c.shikimoriID, sourceURL = c.pageURL, coverURL = c.posterURL, coverLookupDisabled = false).learnNames(c.names)
                    picked = c; go(Step.PROGRESS)
                }, { text -> draft = Entry(title = text.trim()); picked = null; go(Step.PROGRESS) }, "Выбрать и добавить") {
                    Text("Что добавляем?", fontSize = 32.sp, fontWeight = FontWeight.Bold)
                    Footnote("Введите название на русском, английском или оригинале. Ищем в Shikimori и Kitsu — выберите нужный сезон из списка.")
                }
                Step.PROGRESS -> ProgressStep(draft) { draft = it }
                Step.SOURCE -> SourceStep(draft) { draft = it }
                Step.FINISH -> FinishStep(draft, picked) { draft = it }
            }
        }
        if (step != Step.FIND) Row(Modifier.fillMaxWidth().background(LocalShelfColors.current.surface).navigationBarsPadding().imePadding().padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            IosTintedButton(::back, Modifier.height(48.dp)) { Icon(Icons.Filled.ChevronLeft, null); Text("Назад") }
            Spacer(Modifier.width(12.dp))
            when (step) {
                Step.PROGRESS -> Button({ go(Step.SOURCE) }, Modifier.weight(1f).height(48.dp), enabled = draft.title.isNotBlank()) { Text("Далее") }
                Step.SOURCE -> Button({ go(Step.FINISH) }, Modifier.weight(1f).height(48.dp)) { Text(if (hasSource) "Далее" else "Пропустить") }
                else -> Button({ if (duplicate != null) confirmDuplicate = true else save() }, Modifier.weight(1f).height(48.dp), enabled = draft.title.isNotBlank()) {
                    Icon(Icons.Filled.Check, null); Spacer(Modifier.width(6.dp)); Text("Добавить в коллекцию")
                }
            }
        }
    }
    if (confirmClose) AlertDialog({ confirmClose = false }, title = { Text("Закрыть без сохранения?") }, text = { Text("Введённые данные не сохранятся.") },
        confirmButton = { TextButton({ confirmClose = false; navigator.pop() }) { Text("Закрыть", color = Danger) } },
        dismissButton = { TextButton({ confirmClose = false }) { Text("Продолжить добавление") } })
    if (confirmDuplicate) AlertDialog({ confirmDuplicate = false }, title = { Text("Такая история уже есть: «${duplicate?.title ?: ""}»") },
        text = { Text("Совпало одно из названий. Если это другой сезон или фильм, добавьте ещё одну запись.") },
        confirmButton = { TextButton({ confirmDuplicate = false; save() }) { Text("Всё равно добавить") } },
        dismissButton = { TextButton({ confirmDuplicate = false }) { Text("Назад") } })
    problem?.let { AlertDialog({ problem = null }, confirmButton = { TextButton({ problem = null }) { Text("Понятно") } }, title = { Text("Не удалось добавить") }, text = { Text(it) }) }
}

@Composable
private fun ProgressStep(draft: Entry, onChange: (Entry) -> Unit) {
    val icons: Map<WatchStatus, ImageVector> = mapOf(WatchStatus.WATCHING to Icons.Filled.PlayArrow, WatchStatus.PLANNED to Icons.Filled.Schedule,
        WatchStatus.COMPLETED to Icons.Filled.CheckCircle, WatchStatus.DROPPED to Icons.Filled.Cancel)
    var episodeText by remember { mutableStateOf(draft.episode.toString()) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Row {
            CoverImage(draft.coverData, draft.coverURL, Modifier.size(84.dp, 118.dp).clip(RoundedCornerShape(14.dp)), maxSide = 400)
            Spacer(Modifier.width(14.dp))
            Column {
                IosTextField(draft.title, { onChange(draft.copy(title = it.take(500))) }, Modifier.fillMaxWidth(), label = { Text("Ваше название") })
                if (draft.originalTitle.isNotEmpty() && draft.originalTitle != draft.title) Footnote(draft.originalTitle)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Статус", fontWeight = FontWeight.Bold)
            WatchStatus.entries.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    pair.forEach { s ->
                        val selected = draft.status == s
                        Row(Modifier.weight(1f).height(48.dp).clip(RoundedCornerShape(14.dp)).background(if (selected) Accent.copy(alpha = 0.2f) else LocalShelfColors.current.primaryText.copy(alpha = 0.08f))
                            .clickable { onChange(draft.copy(status = s)) }, horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            Icon(icons.getValue(s), null, tint = if (selected) Accent else LocalShelfColors.current.primaryText, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp)); Text(s.raw, color = if (selected) Accent else LocalShelfColors.current.primaryText, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                        }
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("На какой серии вы остановились?", fontWeight = FontWeight.Bold)
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilledTonalIconButton({ val v = maxOf(0, draft.episode - 1); episodeText = v.toString(); onChange(draft.copy(episode = v)) }, Modifier.size(52.dp)) { Icon(Icons.Filled.Remove, "Уменьшить номер серии") }
                IosTextField(episodeText, { t -> episodeText = t.filter(Char::isDigit).take(7); onChange(draft.copy(episode = episodeText.toIntOrNull() ?: 0)) },
                    Modifier.weight(1f).padding(horizontal = 12.dp), singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    textStyle = MaterialTheme.typography.headlineMedium.copy(textAlign = androidx.compose.ui.text.style.TextAlign.Center, fontWeight = FontWeight.Bold))
                FilledTonalIconButton({ val v = minOf(1_000_000, draft.episode + 1); episodeText = v.toString(); onChange(draft.copy(episode = v)) }, Modifier.size(52.dp)) { Icon(Icons.Filled.Add, "Увеличить номер серии") }
            }
            Footnote("0 — ещё не начинали. Номер можно вести сквозной, как вам удобно: приложение его не меняет само.")
        }
        Column {
            Text("Сезон", fontWeight = FontWeight.Bold)
            SwitchRow("Указать сезон", draft.season != null, { onChange(draft.copy(season = if (it) draft.season ?: 1 else null)) })
            draft.season?.let { season ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Сезон $season", Modifier.weight(1f))
                    IconButton({ onChange(draft.copy(season = maxOf(1, season - 1))) }) { Icon(Icons.Filled.Remove, "Меньше") }
                    IconButton({ onChange(draft.copy(season = minOf(10000, season + 1))) }) { Icon(Icons.Filled.Add, "Больше") }
                }
            }
            Footnote("Необязательно. Сезон не определяется автоматически.")
        }
    }
}

@Composable
private fun SourceStep(draft: Entry, onChange: (Entry) -> Unit) {
    val context = LocalContext.current
    val assistant = remember { ShelfAssistant.get(context) }
    val store = rememberStore()
    val prefs = rememberSnapshot().preferences
    val scope = rememberCoroutineScope()
    var suggestions by remember { mutableStateOf<List<AnivibeCatalog.Page>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var address by remember { mutableStateOf("") }
    var page by remember { mutableStateOf<SourcePage?>(null) }
    var loading by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    fun load() {
        loading = true; message = null; page = null
        val target = address
        scope.launch { try { page = assistant.readPage(target) } catch (e: CancellationException) { throw e } catch (e: Exception) { message = e.message }; loading = false }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Где вы смотрите?", fontSize = 32.sp, fontWeight = FontWeight.Bold)
        Footnote("Подключите озвучку на AniVibe, чтобы видеть «+N серий» и получать уведомления о новых. Шаг можно пропустить и вернуться к нему позже в карточке.")
        if (draft.subscriptions.isNotEmpty()) Card {
            Text("Подключено", fontWeight = FontWeight.Bold)
            draft.subscriptions.forEach { s ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text(s.label, fontWeight = FontWeight.SemiBold); s.lastEpisode?.let { Footnote("Сейчас доступна серия $it") } }
                    IconButton({ onChange(draft.copy(subscriptions = draft.subscriptions.filter { it.id != s.id })) }) { Icon(Icons.Filled.RemoveCircleOutline, "Убрать источник ${s.label}") }
                }
            }
        }
        Button({
            searching = true; suggestions = null; message = null
            val entry = draft
            scope.launch { try { suggestions = assistant.anivibeCandidates(entry) } catch (e: CancellationException) { throw e } catch (e: Exception) { message = e.message }; searching = false }
        }, Modifier.fillMaxWidth().height(48.dp), enabled = !searching && draft.title.isNotBlank()) {
            if (searching) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = LocalShelfColors.current.primaryText)
            else Icon(Icons.Filled.TravelExplore, null)
            Spacer(Modifier.width(8.dp)); Text("Найти на AniVibe по названиям")
        }
        suggestions?.let { list ->
            if (list.isEmpty()) Footnote("Страница не найдена ни по одному названию. Вставьте ссылку ниже или вернитесь и добавьте английское название.")
            list.forEach { p ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(LocalShelfColors.current.surface).clickable { address = p.url; suggestions = null; load() }.padding(12.dp)) {
                    Text(p.slugName.split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } })
                    Footnote(p.url)
                }
            }
        }
        Text("Или вставьте ссылку на страницу AniVibe", fontWeight = FontWeight.Bold)
        IosTextField(address, { address = it }, Modifier.fillMaxWidth(), placeholder = { Text("https://anivibe.pro/anime/…") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        IosTintedButton(::load, enabled = !loading && address.isNotBlank()) { Text("Проверить страницу") }
        if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        message?.let { Footnote(it) }
        page?.let { p ->
            Text(p.title, fontWeight = FontWeight.Bold)
            if (!TitleMatcher.matches(p.names + p.title, draft)) Footnote("⚠ Названия страницы не совпали ни с одним названием этой истории. Проверьте, что это то же произведение и нужный сезон.", color = Orange)
            Footnote("Выберите озвучку и сезон. Звёздочка добавляет озвучку в любимые: такие идут первыми.")
            Dubs.sorted(p.options, prefs.favoriteDubs).forEach { option ->
                SourceOptionRow(option, prefs.favoriteDubs, draft.subscriptions.any { it.pageURL == p.url && it.optionID == option.id },
                    onFavorite = { name -> store.setPreferences { it.copy(favoriteDubs = Dubs.toggled(name, it.favoriteDubs)) } }) {
                    draft.attachSource(p, option)?.let { onChange(it); page = null; message = "Подключено: ${option.label}. Сейчас доступна серия ${option.episode}." }
                }
            }
        }
        Text("Ссылка для просмотра", fontWeight = FontWeight.Bold)
        IosTextField(draft.watchURL, { onChange(draft.copy(watchURL = it)) }, Modifier.fillMaxWidth(), placeholder = { Text("https://…") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
        Footnote("Необязательно. Кнопка «Открыть страницу просмотра» откроет её. Остальные площадки и плейлисты можно добавить позже с подписями.")
    }
}

@Composable
fun SourceOptionRow(option: SourceOption, favorites: List<String>, connected: Boolean, onFavorite: (String) -> Unit, onConnect: () -> Unit) {
    val name = Dubs.name(option.label)
    val favorite = Dubs.isFavorite(name, favorites)
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(LocalShelfColors.current.surface).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton({ onFavorite(name) }) { Icon(if (favorite) Icons.Filled.Star else Icons.Filled.StarBorder, if (favorite) "Убрать «$name» из любимых озвучек" else "Добавить «$name» в любимые озвучки", tint = Gold) }
        Column(Modifier.weight(1f).clickable(enabled = !connected, onClick = onConnect).padding(vertical = 10.dp)) {
            Text(option.label)
            Text(if (connected) "Подключено" else "Доступно серий: ${option.episode} · Подключить", color = if (connected) LocalShelfColors.current.secondaryText else Accent, fontSize = 14.sp)
        }
    }
}

@Composable
private fun FinishStep(draft: Entry, picked: AnimeCandidate?, onChange: (Entry) -> Unit) {
    val context = LocalContext.current
    var tagsText by remember { mutableStateOf(draft.tags.joinToString(", ")) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Почти готово", fontSize = 32.sp, fontWeight = FontWeight.Bold)
        Card {
            Row {
                CoverImage(draft.coverData, draft.coverURL, Modifier.size(84.dp, 118.dp).clip(RoundedCornerShape(14.dp)), maxSide = 400)
                Spacer(Modifier.width(14.dp))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(draft.title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Footnote("${draft.status.raw} · серия ${draft.episode}" + (draft.season?.let { " · сезон $it" } ?: ""))
                    if (draft.subscriptions.isNotEmpty()) Text("Источников серий: ${draft.subscriptions.size}", color = Accent, fontSize = 13.sp)
                    else if (draft.watchURL.isNotBlank()) Text("Есть ссылка для просмотра", color = Accent, fontSize = 13.sp)
                    Footnote(if (picked != null && draft.coverURL.isNotEmpty()) "Обложка из каталога" else "Обложка подберётся автоматически")
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Дни выхода", fontWeight = FontWeight.Bold)
            WeekdayPicker(draft.releaseDays) { onChange(draft.copy(releaseDays = it)) }
            Footnote("Отметьте дни недели, когда обычно выходит серия: в эти дни придёт одна сводка, если она включена в Настройках. Приложение дни не угадывает.")
        }
        Column {
            Text("Премьера", fontWeight = FontWeight.Bold)
            SwitchRow("Дата премьеры", draft.premiereDate != null, { on ->
                onChange(draft.copy(premiereDate = if (on) draft.premiereDate ?: LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant() else null))
            })
            draft.premiereDate?.let { premiere ->
                NavRow("Премьера", Icons.Filled.Event, formatDate(premiere)) {
                    val d = premiere.atZone(ZoneId.systemDefault()).toLocalDate()
                    DatePickerDialog(context, { _, y, m, day -> onChange(draft.copy(premiereDate = LocalDate.of(y, m + 1, day).atStartOfDay(ZoneId.systemDefault()).toInstant())) }, d.year, d.monthValue - 1, d.dayOfMonth).show()
                }
            }
            Footnote("В день премьеры в 10:00 придёт одно напоминание.")
        }
        Column { Text("Оценка", fontWeight = FontWeight.Bold); RatingStars(draft.rating, { onChange(draft.copy(rating = it)) }) }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Метки и заметка", fontWeight = FontWeight.Bold)
            IosTextField(tagsText, { tagsText = it; onChange(draft.copy(tags = Tags.parse(it))) }, Modifier.fillMaxWidth(), placeholder = { Text("Метки через запятую: дунхуа, с другом") })
            IosTextField(draft.note, { onChange(draft.copy(note = it.take(20000))) }, Modifier.fillMaxWidth(), placeholder = { Text("Заметка") }, minLines = 2)
        }
    }
}
