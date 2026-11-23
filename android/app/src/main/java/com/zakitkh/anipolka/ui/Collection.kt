package com.zakitkh.anipolka.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalDensity
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import kotlinx.coroutines.launch
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import java.time.Instant

/** Lets a horizontal row reach the screen edges inside a padded list. */
fun Modifier.bleed(horizontal: Dp) = layout { measurable, constraints ->
    val extra = horizontal.roundToPx() * 2
    val placeable = measurable.measure(constraints.copy(minWidth = constraints.maxWidth + extra, maxWidth = constraints.maxWidth + extra))
    layout(constraints.maxWidth, placeable.height) { placeable.place(-horizontal.roundToPx(), 0) }
}

@Composable
fun CollectionScreen() {
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val colors = LocalShelfColors.current
    var query by rememberSaveable { mutableStateOf("") }
    var status by remember { mutableStateOf<WatchStatus?>(null) }
    var favoritesOnly by remember { mutableStateOf(false) }
    var tag by remember { mutableStateOf<String?>(null) }
    var behind by remember { mutableStateOf(false) }
    var dub by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    val prefs = snapshot.preferences
    val filtering = query.isNotBlank() || status != null || favoritesOnly || tag != null || behind || dub != null
    val entries = snapshot.visible(query, status, favoritesOnly, tag, behind, dub)
    val hero = ReleasePlanner.continuing(snapshot.entries, 1).firstOrNull()
    val today = remember(snapshot) {
        val releases = ReleasePlanner.due(snapshot.entries, ReleasePlanner.weekday(Instant.now()))
        val premieres = PremierePlanner.upcoming(snapshot.entries).filter { e -> e.premiereDate?.let { PremierePlanner.label(it) == "Премьера сегодня" } ?: false }
        releases + premieres.filter { p -> releases.none { it.id == p.id } }
    }
    val watching = snapshot.entries.count { it.status == WatchStatus.WATCHING }
    val headline = listOfNotNull(Greeting.text(), when { today.isNotEmpty() -> "сегодня выходит: ${today.size}"; watching > 0 -> "в процессе: $watching"; else -> null }).joinToString(" · ")
    val full: androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    val grid = rememberLazyGridState()
    val haze = rememberHazeState()
    val scope = rememberCoroutineScope()
    val searchFocus = remember { FocusRequester() }
    val density = LocalDensity.current
    val collapsed by remember { derivedStateOf { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > with(density) { 44.dp.roundToPx() } } }

    Box(Modifier.fillMaxSize()) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        state = grid,
        modifier = Modifier.fillMaxSize().background(colors.background).hazeSource(haze),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = contentTopPadding(), bottom = contentBottomPadding()),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item(span = full) {
            Column {
                LargeTitle("Коллекция", headline)
                Spacer(Modifier.height(10.dp))
                SearchField(query, { query = it }, "Найти в коллекции", Modifier.focusRequester(searchFocus))
            }
        }
        store.loadFailure?.let { failure ->
            item(span = full) { Card { Text(failure, color = Orange) } }
        }
        if (!filtering && prefs.showContinue && hero != null) item(span = full) { HeroCard(hero) }
        if (!filtering && today.isNotEmpty()) item(span = full) { TodayRow(today) }
        item(span = full) {
            Row(Modifier.bleed(20.dp).horizontalScrollRow().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChipPill("Все", !filtering, { query = ""; status = null; favoritesOnly = false; tag = null; behind = false; dub = null })
                FilterChipPill("★ Избранное", favoritesOnly, { favoritesOnly = !favoritesOnly })
                WatchStatus.entries.forEach { s -> FilterChipPill(s.raw, status == s, { status = if (status == s) null else s }) }
                if (behind || snapshot.entries.any { Backlog.available(it) != null }) FilterChipPill("Есть новые серии", behind, { behind = !behind })
                Tags.all(snapshot.entries).forEach { t -> FilterChipPill("#$t", tag == t, { tag = if (tag == t) null else t }) }
                Dubs.inUse(snapshot.entries, prefs.favoriteDubs).forEach { d -> FilterChipPill("Озвучка: $d", dub == d, { dub = if (dub == d) null else d }) }
            }
        }
        item(span = full) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (favoritesOnly) "Избранное" else "Мой список", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.width(8.dp))
                Text("${entries.size}", color = colors.secondaryText, fontSize = 20.sp)
                Spacer(Modifier.weight(1f))
                Box {
                    GlassIconButton(Icons.Filled.MoreHoriz, "Вид и сортировка", { menu = true }, tint = Accent, size = 40.dp)
                    DropdownMenu(menu, { menu = false }, shape = RoundedCornerShape(18.dp), containerColor = colors.surfaceHigh) {
                        ShelfSort.entries.forEach { s ->
                            DropdownMenuItem({ Text(s.raw) }, { store.setPreferences { it.copy(sort = s) }; menu = false },
                                leadingIcon = { if (prefs.sort == s) Icon(Icons.Filled.Check, null) })
                        }
                        HorizontalDivider()
                        Layout.entries.forEach { l ->
                            DropdownMenuItem({ Text(l.label) }, { store.setPreferences { it.copy(layout = l) }; menu = false },
                                leadingIcon = { if (prefs.layout == l) Icon(Icons.Filled.Check, null) })
                        }
                        DropdownMenuItem({ Text("Группы по статусам") }, { store.setPreferences { it.copy(shelves = !it.shelves) }; menu = false },
                            leadingIcon = { if (prefs.shelves) Icon(Icons.Filled.Check, null) })
                        HorizontalDivider()
                        DropdownMenuItem({ Text("Изменить порядок") }, { menu = false; navigator.push(Route.Reorder) }, leadingIcon = { Icon(Icons.Filled.Reorder, null) })
                        DropdownMenuItem({ Text("Импорт текстового списка") }, { menu = false; navigator.push(Route.Import) }, leadingIcon = { Icon(Icons.Filled.PlaylistAdd, null) })
                        DropdownMenuItem({ Text("Что посмотреть?") }, { menu = false; navigator.push(Route.Suggestion) }, leadingIcon = { Icon(Icons.Filled.Casino, null) })
                        DropdownMenuItem({ Text("Поделиться списком текстом") }, {
                            menu = false
                            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, ShelfExport.text(entries)), "Мой список АниПолки"))
                        }, leadingIcon = { Icon(Icons.Filled.Share, null) })
                    }
                }
            }
        }
        when {
            entries.isEmpty() -> item(span = full) { EmptyState(filtering) }
            prefs.shelves && !filtering -> ShelfSections.make(entries).forEach { section ->
                item(span = full) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(section.title, fontSize = 20.sp, fontWeight = FontWeight.Bold); Spacer(Modifier.width(8.dp))
                        Text("${section.entries.size}", color = colors.secondaryText)
                    }
                }
                posterItems(section.entries)
            }
            prefs.layout == Layout.GRID -> posterItems(entries)
            else -> items(entries, key = { "row-${it.id}" }, span = { GridItemSpan(maxLineSpan) }) { ShelfRow(it) }
        }
    }
    GlassTopBar("Коллекция", collapsed, haze) {
        GlassIconButton(Icons.Filled.Search, "Поиск в коллекции", {
            scope.launch { grid.animateScrollToItem(0); runCatching { searchFocus.requestFocus() } }
        })
        GlassIconButton(Icons.Filled.Add, "Добавить произведение", { navigator.push(Route.Wizard) })
    }
    }
}

private fun LazyGridScope.posterItems(entries: List<Entry>) = items(entries, key = { "poster-${it.id}" }) { PosterCard(it) }

@Composable
private fun Modifier.horizontalScrollRow() = this.then(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()))

@Composable
fun SearchField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val colors = LocalShelfColors.current
    Row(Modifier.fillMaxWidth().height(44.dp).clip(CircleShape).background(if (colors.dark) Color(0xFF1C1C1F) else Color(0xFFE3E3E8)).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Search, null, tint = colors.secondaryText)
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(placeholder, color = colors.secondaryText, fontSize = 17.sp)
            BasicTextField(value, onChange, singleLine = true, textStyle = TextStyle(color = colors.primaryText, fontSize = 17.sp), cursorBrush = SolidColor(Accent), modifier = modifier.fillMaxWidth())
        }
        if (value.isNotEmpty()) Icon(Icons.Filled.Cancel, "Очистить", Modifier.clip(CircleShape).clickable { onChange("") }, tint = colors.secondaryText)
    }
}

@Composable
private fun EmptyState(filtering: Boolean) {
    val navigator = LocalNavigator.current
    Column(Modifier.fillMaxWidth().padding(vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(if (filtering) Icons.Filled.Search else Icons.Filled.MenuBook, null, tint = Accent, modifier = Modifier.size(48.dp))
        Text(if (filtering) "Ничего не найдено" else "Ваша полка ждёт первую историю", fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Footnote(if (filtering) "Измените поиск или сбросьте фильтры: кнопка «Все»." else "Найдите произведение с обложкой или перенесите свой текстовый список.")
        if (!filtering) {
            Button({ navigator.push(Route.Wizard) }) { Icon(Icons.Filled.Add, null); Spacer(Modifier.width(6.dp)); Text("Добавить историю") }
            TextButton({ navigator.push(Route.Import) }) { Text("Перенести текстовый список") }
        }
    }
}

@Composable
fun HeroCard(entry: Entry) {
    val navigator = LocalNavigator.current
    Box(Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(28.dp))) {
        Box(Modifier.fillMaxSize().clickable { navigator.push(Route.Detail(entry.id)) }.semantics { contentDescription = "Открыть ${entry.title}" }) {
            CoverImage(entry.coverData, entry.coverURL, Modifier.fillMaxSize(), entry.id, 48.dp, 1200)
            Row(Modifier.padding(14.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.45f)).border(0.8.dp, Color.White.copy(alpha = 0.25f), CircleShape).padding(horizontal = 11.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp)); Text("Продолжить", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
            Column(
                Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.82f))))
                    .padding(start = 18.dp, end = 86.dp, bottom = 20.dp, top = 48.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(entry.title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Серия ${entry.episode}", color = Color.White.copy(alpha = 0.9f), fontSize = 15.sp)
                    val available = Backlog.available(entry)
                    if (available != null) { Spacer(Modifier.width(8.dp)); CountPill("+$available") }
                    else if (Backlog.caughtUp(entry)) { Spacer(Modifier.width(8.dp)); Text("⌛ Догнал", color = Color.White.copy(alpha = 0.85f), fontSize = 13.sp) }
                }
                Backlog.progress(entry)?.let { ProgressLine(it) }
            }
        }
        IncrementButton(entry, Modifier.align(Alignment.BottomEnd).padding(14.dp), onDark = true)
    }
}

@Composable
fun CountPill(text: String) = Text(text, Modifier.clip(CircleShape).background(Accent).padding(horizontal = 8.dp, vertical = 3.dp), color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)

@Composable
private fun TodayRow(entries: List<Entry>) {
    val navigator = LocalNavigator.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text("Сегодня выходит", fontSize = 20.sp, fontWeight = FontWeight.Bold); Spacer(Modifier.width(8.dp))
            Text("${entries.size}", color = LocalShelfColors.current.secondaryText)
        }
        LazyRow(Modifier.bleed(20.dp), contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(entries, key = { it.id }) { e ->
                Row(
                    Modifier.width(240.dp).clip(RoundedCornerShape(18.dp)).background(LocalShelfColors.current.surface).clickable { navigator.push(Route.Detail(e.id)) }.padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CoverImage(e.coverData, e.coverURL, Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(9.dp)), e.id, 18.dp, 300)
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(e.title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 15.sp)
                        Text("Следующая: ${e.episode + 1}", color = Orange, fontSize = 13.sp)
                    }
                }
            }
        }
    }
}

/** Every card has the same height: a 2:3 cover, a two-line title and one action row. */
@Composable
fun PosterCard(entry: Entry) {
    val navigator = LocalNavigator.current
    val releasesToday = ReleasePlanner.weekday(Instant.now()) in entry.releaseDays && (entry.status == WatchStatus.WATCHING || entry.status == WatchStatus.PLANNED)
    val spoken = listOfNotNull(entry.title, "серия ${entry.episode}", Backlog.available(entry)?.let { "доступно ещё $it" },
        if (Backlog.caughtUp(entry)) "догнал" else null, if (entry.favorite) "избранное" else null, if (releasesToday) "сегодня выход" else null,
        entry.rating?.let { "оценка $it из 5" }).joinToString(", ")
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.clip(RoundedCornerShape(20.dp)).clickable { navigator.push(Route.Detail(entry.id)) }.semantics(mergeDescendants = true) { contentDescription = spoken },
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(20.dp))) {
                CoverImage(entry.coverData, entry.coverURL, Modifier.fillMaxSize(), entry.id)
                Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    if (entry.favorite) CoverBadge(Icons.Filled.Star, Gold)
                    if (releasesToday) CoverBadge(Icons.Outlined.CalendarMonth, Orange)
                    if (Backlog.caughtUp(entry)) CoverBadge(Icons.Filled.HourglassBottom, Color.White)
                }
                val available = Backlog.available(entry)
                if (available != null) Box(Modifier.align(Alignment.TopEnd).padding(8.dp)) { CountPill("+$available") }
                else Airing.upcoming(entry)?.takeIf { it.isBefore(Instant.now().plusSeconds(8 * 86400)) }?.let { Box(Modifier.align(Alignment.TopEnd).padding(8.dp)) { CountdownChip(it) } }
                Backlog.progress(entry)?.let { ProgressLine(it, Modifier.align(Alignment.BottomCenter).padding(10.dp)) }
            }
            Text(entry.title, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Серия ${entry.episode}", color = LocalShelfColors.current.secondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f), maxLines = 1)
            IncrementButton(entry)
        }
    }
}

@Composable
private fun ShelfRow(entry: Entry) {
    val navigator = LocalNavigator.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).clip(RoundedCornerShape(14.dp)).clickable { navigator.push(Route.Detail(entry.id)) }, verticalAlignment = Alignment.CenterVertically) {
            CoverImage(entry.coverData, entry.coverURL, Modifier.size(64.dp, 88.dp).clip(RoundedCornerShape(12.dp)), entry.id, 22.dp, 400)
            Spacer(Modifier.width(14.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(entry.displayTitle, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                Text(entry.subtitle, color = LocalShelfColors.current.secondaryText, fontSize = 14.sp)
                if (entry.status != WatchStatus.WATCHING) Text(entry.status.raw, color = Accent, fontSize = 12.sp)
                EntryBadges(entry)
            }
        }
        Spacer(Modifier.width(10.dp))
        IncrementButton(entry)
    }
}

@Composable
fun EntryBadges(entry: Entry) {
    val available = Backlog.available(entry)
    val today = ReleasePlanner.weekday(Instant.now()) in entry.releaseDays && (entry.status == WatchStatus.WATCHING || entry.status == WatchStatus.PLANNED)
    val premiere = PremierePlanner.upcoming(listOf(entry)).firstOrNull()?.premiereDate
    val airing = Airing.upcoming(entry)
    if (available == null && !today && !Backlog.caughtUp(entry) && premiere == null && entry.rating == null && airing == null) return
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        available?.let { Text("+$it ${episodesWord(it)}", color = Accent, fontWeight = FontWeight.Bold, fontSize = 12.sp) }
        if (Backlog.caughtUp(entry)) Text("⌛ Догнал", color = LocalShelfColors.current.secondaryText, fontSize = 12.sp)
        if (airing != null) Text("Серия ${Airing.nextEpisode(entry) ?: "?"} ${Airing.countdown(airing)}", color = Orange, fontSize = 12.sp)
        else if (today) Text("Сегодня выход", color = Orange, fontSize = 12.sp)
        premiere?.let { Text(PremierePlanner.label(it), color = Orange, fontSize = 12.sp) }
        entry.rating?.let { Text("★".repeat(it), color = Gold, fontSize = 12.sp) }
    }
}
