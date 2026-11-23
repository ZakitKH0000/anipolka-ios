package com.zakitkh.anipolka.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.Notifications
import com.zakitkh.anipolka.data.ShelfAssistant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import java.util.UUID

/** Asks for the Android 13+ notification permission; returns a function that requests it and reports the result. */
@Composable
fun rememberNotificationPermission(onResult: (Boolean) -> Unit): () -> Unit {
    val context = LocalContext.current
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { onResult(it) }
    return { if (Build.VERSION.SDK_INT >= 33 && !Notifications.allowed(context)) launcher.launch(Manifest.permission.POST_NOTIFICATIONS) else onResult(true) }
}

@Composable
fun ReleasesScreen() {
    val context = LocalContext.current
    val assistant = remember { ShelfAssistant.get(context) }
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    val checking by assistant.checking.collectAsState()
    val message by assistant.message.collectAsState()
    val scope = rememberCoroutineScope()
    val byID = snapshot.entries.associateBy { it.id }
    val notices = snapshot.entries.flatMap { e -> e.releaseNotices.map { e.id to it } }.sortedByDescending { it.second.foundAt }
    val fresh = notices.filter { !it.second.read }
    val earlier = notices.filter { it.second.read }
    val sequels = snapshot.entries.mapNotNull { e -> Airing.sequelSuggestion(e, snapshot)?.let { e to it } }
    val calendar = remember(snapshot) { Airing.calendar(snapshot.entries) }
    var menu by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var showAllEarlier by rememberSaveable { mutableStateOf(false) }
    val scroll = rememberScrollState()
    val haze = rememberHazeState()
    val density = LocalDensity.current
    val collapsed by remember { derivedStateOf { scroll.value > with(density) { 44.dp.roundToPx() } } }
    val colors = LocalShelfColors.current
    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().hazeSource(haze).verticalScroll(scroll).padding(start = 16.dp, end = 16.dp, top = contentTopPadding(), bottom = contentBottomPadding())) {
        LargeTitle("Новые серии", when {
            fresh.isNotEmpty() -> "Не просмотрено: ${fresh.size}"
            notices.isNotEmpty() -> "Всё просмотрено"
            else -> null
        })

        if (fresh.isNotEmpty()) {
            IosGroup(header = "Новые", inset = 76.dp, footer = "Смахните вправо — прочитано, влево — удалить. Отметка «+1» в карточке сама убирает серии, которые вы посмотрели.") {
                fresh.forEach { (entryID, notice) ->
                    val entry = byID[entryID] ?: return@forEach
                    key(notice.id) {
                        NoticeRow(entry, notice, onRead = { store.change { NoticeInbox.markRead(it, entryID, notice.id) } },
                            onDelete = { store.change { NoticeInbox.remove(it, entryID, notice.id) } })
                    }
                }
            }
        }

        ReleaseCalendar(calendar)

        if (sequels.isNotEmpty()) {
            IosGroup(header = "Продолжения") {
                sequels.forEach { (e, hint) ->
                    key("sequel-${e.id}") {
                        SequelRow(e, hint, onAdd = { addSequel(store, e.id, hint) },
                            onHide = { store.change { s -> s.withEntry(e.id) { it.copy(dismissedSequelID = hint.id) } } })
                    }
                }
            }
        }

        IosGroup(inset = 60.dp, footer = "Фоновую проверку запускает Android. Она может задерживаться, особенно в режиме экономии заряда. Даты выхода берутся из Shikimori: это время показа в Японии или Китае, озвучка обычно позже.") {
            IosRow("Проверить сейчас", icon = Icons.Filled.Refresh, titleColor = Accent, enabled = !checking, onClick = { scope.launch { assistant.checkReleases(); assistant.refreshAiring(force = true) } },
                trailing = if (checking) ({ CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }) else null)
            IosRow("Неделя: выходы и премьеры", icon = Icons.Filled.CalendarMonth, chevron = true, onClick = { navigator.push(Route.Week) })
            message?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 12.dp), color = colors.secondaryText, fontSize = 15.sp) }
        }

        if (notices.isEmpty()) {
            IosGroup {
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 26.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.VideoLibrary, null, Modifier.size(40.dp), tint = colors.secondaryText)
                    Text("Новые серии появятся здесь", Modifier.padding(top = 10.dp), fontSize = 19.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    Text("Откройте историю → «Источники новых серий» и выберите страницу, сезон и озвучку AniVibe.", Modifier.padding(top = 6.dp),
                        color = colors.secondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
                }
            }
        }

        if (earlier.isNotEmpty()) {
            val shown = if (showAllEarlier) earlier else earlier.take(5)
            IosGroup(header = "Просмотренные", inset = 76.dp, footer = "Просмотренные уведомления удаляются сами через ${NoticeInbox.KEEP_READ_DAYS} дней.") {
                shown.forEach { (entryID, notice) ->
                    val entry = byID[entryID] ?: return@forEach
                    key(notice.id) {
                        NoticeRow(entry, notice, onRead = {}, onDelete = { store.change { NoticeInbox.remove(it, entryID, notice.id) } })
                    }
                }
                if (earlier.size > 5) IosRow(if (showAllEarlier) "Свернуть" else "Показать все (${earlier.size})", titleColor = Accent, onClick = { showAllEarlier = !showAllEarlier })
            }
        }

        val connected = snapshot.entries.filter { it.subscriptions.isNotEmpty() }
        if (connected.isNotEmpty()) {
            IosGroup(header = "Подключённые истории") {
                connected.forEach { e ->
                    IosRow(e.title, chevron = true, onClick = { navigator.push(Route.Detail(e.id)) },
                        subtitle = "Источников: ${e.subscriptions.size}" + if (e.subscriptions.any { it.error != null }) " · ⚠ есть недоступный" else "")
                }
            }
        }
    }
    GlassTopBar("Новые серии", collapsed, haze) {
        if (notices.isNotEmpty()) Box {
            GlassIconButton(Icons.Filled.MoreHoriz, "Действия с уведомлениями", { menu = true })
            DropdownMenu(menu, { menu = false }, shape = RoundedCornerShape(18.dp), containerColor = colors.surfaceHigh) {
                if (fresh.isNotEmpty()) DropdownMenuItem({ Text("Прочитать все (${fresh.size})") }, { menu = false; store.change { NoticeInbox.markAllRead(it) } },
                    leadingIcon = { Icon(Icons.Filled.DoneAll, null) })
                if (earlier.isNotEmpty()) DropdownMenuItem({ Text("Удалить просмотренные") }, { menu = false; store.change { NoticeInbox.removeRead(it) } },
                    leadingIcon = { Icon(Icons.Filled.DeleteSweep, null) })
                DropdownMenuItem({ Text("Удалить все уведомления", color = Danger) }, { menu = false; confirmClear = true },
                    leadingIcon = { Icon(Icons.Filled.DeleteForever, null, tint = Danger) })
            }
        }
    }
    }
    if (confirmClear) AlertDialog({ confirmClear = false }, title = { Text("Удалить все уведомления?") },
        text = { Text("Список найденных серий очистится. Прогресс, источники и коллекция не изменятся; новые серии продолжат появляться.") },
        confirmButton = { TextButton({ confirmClear = false; store.change { NoticeInbox.removeAll(it) } }) { Text("Удалить", color = Danger) } },
        dismissButton = { TextButton({ confirmClear = false }) { Text("Отмена") } })
}

/** Small tinted capsule button, like the bordered buttons inside iOS list rows. */
@Composable
fun SmallPill(text: String, filled: Boolean, onClick: () -> Unit) {
    Text(
        text,
        Modifier.clip(CircleShape).background(if (filled) Accent.copy(alpha = 0.18f) else LocalShelfColors.current.primaryText.copy(alpha = 0.08f))
            .clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
        color = if (filled) Accent else LocalShelfColors.current.primaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
    )
}

@Composable
fun WeekScreen() {
    val snapshot = rememberSnapshot()
    val navigator = LocalNavigator.current
    val dayFormat = DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale("ru"))
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Неделя", navigator::pop)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp)) {
            WeekPlan.days(snapshot.entries).forEach { day ->
                SectionTitle(if (day.date == LocalDate.now()) "Сегодня" else dayFormat.format(day.date).replaceFirstChar { it.uppercase() })
                Card {
                    if (day.releases.isEmpty() && day.premieres.isEmpty()) Footnote("Ничего не отмечено")
                    day.premieres.forEach { Text("✦ $it", color = Orange) }
                    day.releases.forEach { Text("▶ $it") }
                }
            }
            Footnote("Дни выхода указываются в карточке: «Изменить» → «Дни выхода и метки». Там же — дата премьеры.", Modifier.padding(6.dp))
        }
    }
}

@Composable
fun EntrySourcesScreen(entryID: UUID, initial: String?) {
    val context = LocalContext.current
    val assistant = remember { ShelfAssistant.get(context) }
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    val scope = rememberCoroutineScope()
    val entry = snapshot.entry(entryID)
    var address by remember { mutableStateOf(initial ?: entry?.watchURL?.takeIf { AnivibePageParser.canonicalURL(it) != null } ?: entry?.sourceID?.let { "https://anivibe.pro/anime/$it" } ?: "") }
    var page by remember { mutableStateOf<SourcePage?>(null) }
    var loading by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var suggestions by remember { mutableStateOf<List<AnivibeCatalog.Page>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<ReleaseSubscription?>(null) }
    fun load() {
        loading = true; message = null; page = null
        val target = address
        scope.launch { try { page = assistant.readPage(target) } catch (e: CancellationException) { throw e } catch (e: Exception) { message = e.message }; loading = false }
    }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background)) {
        ScreenTopBar("Источники серий", navigator::pop)
        if (entry == null) { Text("Запись удалена", Modifier.padding(24.dp)); return@Column }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 32.dp).imePadding()) {
            SectionTitle("Добавить источник")
            Card {
                IosTextField(address, { address = it }, Modifier.fillMaxWidth(), placeholder = { Text("https://anivibe.pro/anime/…") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                NavRow("Проверить страницу AniVibe", Icons.Filled.Download) { if (!loading && address.isNotBlank()) load() }
                NavRow("Найти на AniVibe по названиям", Icons.Filled.TravelExplore) {
                    if (searching) return@NavRow
                    searching = true; suggestions = null
                    scope.launch { try { suggestions = assistant.anivibeCandidates(entry) } catch (e: CancellationException) { throw e } catch (e: Exception) { message = e.message }; searching = false }
                }
                if (loading || searching) LinearProgressIndicator(Modifier.fillMaxWidth())
                suggestions?.let { list ->
                    if (list.isEmpty()) Footnote("Страница не найдена ни по одному названию. Добавьте английское или оригинальное название в «Другие названия» либо вставьте ссылку вручную.")
                    list.forEach { p -> Column(Modifier.fillMaxWidth().clickable { address = p.url; suggestions = null; load() }.padding(vertical = 6.dp)) {
                        Text(p.slugName.split(' ').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }); Footnote(p.url)
                    } }
                }
                message?.let { Footnote(it) }
                Footnote("Вставьте страницу нужного произведения с сайта. Обложка может подставиться автоматически. Название и ваш прогресс сохранятся.")
            }
            page?.let { p ->
                SectionTitle("Найдено на странице")
                Card {
                    Text(p.title, fontWeight = FontWeight.Bold)
                    if (!TitleMatcher.matches(p.names + p.title, entry)) Footnote("⚠ Названия страницы не совпали ни с одним названием этой истории. Проверьте, что это то же произведение и нужный сезон.", color = Orange)
                    Footnote("Выберите нужные сезон и озвучку. Последняя серия на сайте не всегда использует вашу сквозную нумерацию.")
                    Spacer(Modifier.height(8.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Dubs.sorted(p.options, snapshot.preferences.favoriteDubs).forEach { option ->
                            SourceOptionRow(option, snapshot.preferences.favoriteDubs, entry.subscriptions.any { it.pageURL == p.url && it.optionID == option.id },
                                onFavorite = { name -> store.setPreferences { it.copy(favoriteDubs = Dubs.toggled(name, it.favoriteDubs)) } }) {
                                if (assistant.connect(p, option, entryID)) {
                                    page = null
                                    message = "Источник подключён. Сейчас доступна серия ${option.episode}. Следующие выпуски появятся во вкладке «Серии». Для системных уведомлений включите их в Настройках."
                                    assistant.queueCovers()
                                }
                            }
                        }
                    }
                }
            }
            SectionTitle("Мои источники")
            Card {
                if (entry.subscriptions.isEmpty()) Footnote("Источников пока нет.")
                entry.subscriptions.forEach { s ->
                    Column(Modifier.padding(vertical = 6.dp)) {
                        SwitchRow(s.label, s.enabled, { on -> store.change { st -> st.withEntry(entryID) { en -> en.copy(subscriptions = en.subscriptions.map { if (it.id == s.id) it.copy(enabled = on) else it }) } } })
                        s.lastEpisode?.let { Text("Последняя доступная: $it", fontSize = 15.sp) }
                        s.lastCheckedAt?.let { Footnote("Проверено: ${formatDateTime(it)}") }
                        s.error?.let { Footnote(it, color = Orange) }
                        Row {
                            validWebURL(s.pageURL)?.let { url -> TextButton({ openUrl(context, url) }) { Text("Открыть источник ↗") } }
                            TextButton({ removing = s }) { Text("Отключить источник", color = Danger) }
                        }
                    }
                }
            }
            Footnote("Проверяется наличие серий на выбранной публичной странице. Видео не скачиваются. Плеер открывается на самом сайте.", Modifier.padding(6.dp))
        }
    }
    removing?.let { s ->
        AlertDialog({ removing = null }, title = { Text("Отключить этот источник?") }, text = { Text("Коллекция, просмотренный прогресс и уже найденные выпуски сохранятся.") },
            confirmButton = { TextButton({ removing = null; store.change { st -> st.withEntry(entryID) { en -> en.copy(subscriptions = en.subscriptions.filter { it.id != s.id }) } } }) { Text("Отключить", color = Danger) } },
            dismissButton = { TextButton({ removing = null }) { Text("Отмена") } })
    }
}
