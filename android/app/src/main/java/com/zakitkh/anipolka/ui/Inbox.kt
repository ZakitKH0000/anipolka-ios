package com.zakitkh.anipolka.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

private val ru = Locale("ru")

/** «только что», «5 мин назад», «3 ч назад», «вчера», «12 ноября». */
fun ago(at: Instant, now: Instant = Instant.now()): String {
    val d = Duration.between(at, now)
    val zone = ZoneId.systemDefault()
    val day = ZonedDateTime.ofInstant(at, zone).toLocalDate()
    val today = ZonedDateTime.ofInstant(now, zone).toLocalDate()
    return when {
        d.toMinutes() < 1 -> "только что"
        d.toMinutes() < 60 -> "${d.toMinutes()} мин назад"
        day == today -> "${d.toHours()} ч назад"
        day == today.minusDays(1) -> "вчера"
        else -> DateTimeFormatter.ofPattern("d MMMM", ru).format(day)
    }
}

fun dayTitle(date: LocalDate, today: LocalDate = LocalDate.now()): String = when (date) {
    today -> "Сегодня"
    today.plusDays(1) -> "Завтра"
    else -> DateTimeFormatter.ofPattern("EE, d", ru).format(date).replaceFirstChar { it.uppercase() }
}

/** Seven day pills; the list under them shows what airs on the chosen day. */
@Composable
fun ReleaseCalendar(days: List<CalendarDay>) {
    val navigator = LocalNavigator.current
    val c = LocalShelfColors.current
    var selected by rememberSaveable { mutableIntStateOf(0) }
    val day = days.getOrNull(selected) ?: return
    Column {
        Text("Календарь выхода", Modifier.padding(start = 16.dp, top = 26.dp, bottom = 10.dp), color = c.secondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        LazyRow(Modifier.bleed(16.dp), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(days) { i, d ->
                val active = i == selected
                Column(
                    Modifier.clip(RoundedCornerShape(18.dp))
                        .background(if (active) Accent else c.surface)
                        .clickable { selected = i }.padding(horizontal = 14.dp, vertical = 9.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(dayTitle(d.date), color = if (active) Color.White else c.primaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Text(if (d.items.isEmpty()) "—" else "${d.items.size} ${titlesWord(d.items.size)}",
                        color = if (active) Color.White.copy(alpha = 0.85f) else c.secondaryText, fontSize = 12.sp)
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        IosGroup(spaced = false, inset = 76.dp) {
            if (day.items.isEmpty()) Text("В этот день ничего не отмечено", Modifier.padding(16.dp), color = c.secondaryText, fontSize = 15.sp)
            day.items.forEach { item ->
                val e = item.entry
                Row(
                    Modifier.fillMaxWidth().clickable { navigator.push(Route.Detail(e.id)) }.padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CoverImage(e.coverData, e.coverURL, Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(9.dp)), e.id, 18.dp, 300)
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(e.title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        val at = item.at
                        Text(
                            if (at != null) listOfNotNull(item.episode?.let { "Серия $it" }, DateTimeFormatter.ofPattern("HH:mm").format(ZonedDateTime.ofInstant(at, ZoneId.systemDefault())), Airing.countdown(at)).joinToString(" · ")
                            else "По вашему расписанию · следующая ${e.episode + 1}",
                            color = if (at != null) Orange else c.secondaryText, fontSize = 14.sp,
                        )
                    }
                }
            }
        }
    }
}

/** One found episode: cover, title, episode and dub; swipe right to mark read, left to delete. */
@Composable
fun NoticeRow(entry: Entry, notice: ReleaseNotice, onRead: () -> Unit, onDelete: () -> Unit) {
    val navigator = LocalNavigator.current
    val context = LocalContext.current
    val c = LocalShelfColors.current
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> { onRead(); false }
            SwipeToDismissBoxValue.EndToStart -> { onDelete(); true }
            else -> false
        }
    })
    SwipeToDismissBox(
        state,
        enableDismissFromStartToEnd = !notice.read,
        backgroundContent = {
            val toRead = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            Row(
                Modifier.fillMaxSize().background(if (toRead) Accent else Danger).padding(horizontal = 22.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (toRead) Arrangement.Start else Arrangement.End,
            ) {
                Icon(if (toRead) Icons.Filled.MarkEmailRead else Icons.Filled.Delete, null, tint = Color.White)
                Spacer(Modifier.width(8.dp))
                Text(if (toRead) "Прочитано" else "Удалить", color = Color.White, fontWeight = FontWeight.SemiBold)
            }
        },
    ) {
        Row(
            Modifier.fillMaxWidth().background(c.surface).clickable { onRead(); navigator.push(Route.Detail(entry.id)) }
                .padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box {
                CoverImage(entry.coverData, entry.coverURL, Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(9.dp)), entry.id, 18.dp, 300)
                if (!notice.read) Box(Modifier.align(Alignment.TopStart).offset((-5).dp, (-5).dp).size(12.dp).clip(CircleShape).background(Accent).border(2.dp, c.surface, CircleShape))
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(entry.title, fontSize = 16.sp, fontWeight = if (notice.read) FontWeight.Normal else FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                val jump = notice.episode - notice.previousEpisode
                Text("Серия ${notice.episode}" + if (jump > 1) " (+$jump)" else "", fontSize = 15.sp, color = if (notice.read) c.secondaryText else c.primaryText)
                Text(listOfNotNull(notice.sourceLabel, ago(notice.foundAt)).joinToString(" · "), fontSize = 13.sp, color = c.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            validWebURL(notice.url)?.let { url ->
                Spacer(Modifier.width(8.dp))
                SmallPill("Смотреть", true) { onRead(); openUrl(context, url) }
            }
        }
    }
}

/** «Вышло продолжение»: the next season with Add and Hide. */
@Composable
fun SequelRow(entry: Entry, hint: SequelHint, onAdd: () -> Unit, onHide: () -> Unit) {
    val c = LocalShelfColors.current
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        CoverImage(null, hint.coverURL, Modifier.size(52.dp, 74.dp).clip(RoundedCornerShape(10.dp)), null, 20.dp, 300)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(Airing.sequelLabel(hint), color = if (hint.status == Airing.ANONS) Orange else Success, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            Text(hint.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text("после «${entry.title}»", fontSize = 13.sp, color = c.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                SmallPill("Добавить на потом", true, onAdd)
                SmallPill("Скрыть", false, onHide)
            }
        }
    }
}

/** Broadcast block on the title card: next episode with countdown, aired count, unwatched episodes. */
@Composable
fun AiringCard(e: Entry, accent: Color) {
    val info = e.airing ?: return
    val c = LocalShelfColors.current
    val at = Airing.upcoming(e)
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(at) { while (at != null) { kotlinx.coroutines.delay(30_000); now = Instant.now() } }
    Card(Modifier.animateContentSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Schedule, null, Modifier.size(22.dp), tint = if (at != null) Orange else accent)
            Spacer(Modifier.width(10.dp))
            Text(if (at != null) "Серия ${Airing.nextEpisode(e, now) ?: "?"} · ${Airing.countdown(at, now)}" else Airing.progressText(info),
                fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        }
        if (at != null) Text(Airing.moment(at, now = now).replaceFirstChar { it.uppercase() } + " · " + Airing.progressText(info).lowercase(),
            Modifier.padding(top = 6.dp), color = c.secondaryText, fontSize = 15.sp)
        Airing.aired(e)?.let { n ->
            Text("Уже вышло и не просмотрено: $n ${episodesWord(n)}", Modifier.padding(top = 6.dp), color = accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
        Text("Shikimori · время оригинального показа; озвучка обычно выходит позже. Обновлено ${ago(info.checkedAt)}.",
            Modifier.padding(top = 8.dp), color = c.secondaryText, fontSize = 12.sp)
    }
}

/** Small countdown chip on a cover: «⏱ 2 д». */
@Composable
fun CountdownChip(at: Instant) = Row(
    Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.62f)).border(0.8.dp, Color.White.copy(alpha = 0.2f), CircleShape).padding(horizontal = 8.dp, vertical = 3.dp),
    verticalAlignment = Alignment.CenterVertically,
) {
    Icon(Icons.Filled.Schedule, null, Modifier.size(13.dp), tint = Orange)
    Spacer(Modifier.width(3.dp))
    Text(Airing.shortCountdown(at), color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
}

fun titlesWord(n: Int): String {
    val tens = n % 100; val ones = n % 10
    return if (tens in 11..14) "тайтлов" else if (ones == 1) "тайтл" else if (ones in 2..4) "тайтла" else "тайтлов"
}

/** Adds the continuation to «На потом», linked to the previous part in «Связанные части». */
fun addSequel(store: com.zakitkh.anipolka.data.ShelfStore, from: UUID, hint: SequelHint): Boolean {
    val added = Airing.sequelEntry(hint).copy(relatedIDs = listOf(from))
    return store.change { s -> s.copy(entries = listOf(added) + s.entries) }
}
