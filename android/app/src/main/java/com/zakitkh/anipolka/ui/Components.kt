package com.zakitkh.anipolka.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBackIosNew
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.outlined.LiveTv
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.NetworkService
import com.zakitkh.anipolka.data.ShelfStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

@Composable fun rememberStore(): ShelfStore { val c = LocalContext.current; return remember { ShelfStore.get(c) } }
@Composable fun rememberNetwork(): NetworkService { val c = LocalContext.current; return remember { NetworkService.get(c) } }
@Composable fun rememberSnapshot(): Snapshot = rememberStore().snapshot.collectAsState().value

fun episodesWord(n: Int): String {
    val tens = n % 100; val ones = n % 10
    if (tens in 11..14) return "серий"
    if (ones == 1) return "серия"
    return if (ones in 2..4) "серии" else "серий"
}

object ImageCache {
    private val cache = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    fun get(key: String): ImageBitmap? = cache.get(key)
    fun put(key: String, value: ImageBitmap) { cache.put(key, value) }
    fun decode(bytes: ByteArray, maxSide: Int = 900): ImageBitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
    }
}

/** A cover from the saved bytes, or downloaded once from the catalogue and cached for offline use. */
@Composable
fun CoverImage(data: Blob?, url: String, modifier: Modifier = Modifier, entryID: UUID? = null, iconSize: Dp = 32.dp, maxSide: Int = 900) {
    val context = LocalContext.current
    val network = rememberNetwork()
    val connected by network.connected.collectAsState()
    val wifi by network.wifi.collectAsState()
    val key = remember(data, url) { data?.let { "d${it.hashCode()}-${it.size}-$maxSide" } ?: "u$url-$maxSide" }
    var bitmap by remember(key) { mutableStateOf(ImageCache.get(key)) }
    LaunchedEffect(key, connected, wifi) {
        if (bitmap != null) return@LaunchedEffect
        if (data != null) {
            bitmap = withContext(Dispatchers.Default) { ImageCache.decode(data.bytes, maxSide) }?.also { ImageCache.put(key, it) }
            return@LaunchedEffect
        }
        if (CoverImagePolicy.isPlaceholder(url) || CoverImagePolicy.usableURL(url) == null || !network.canLoadCovers) return@LaunchedEffect
        val bytes = runCatching { network.image(url) }.getOrNull() ?: return@LaunchedEffect
        bitmap = withContext(Dispatchers.Default) { ImageCache.decode(bytes, maxSide) }?.also { ImageCache.put(key, it) }
        if (entryID != null) ShelfStore.get(context).cacheCover(entryID, url, bytes)
    }
    Box(modifier.background(Brush.linearGradient(listOf(Color(0x4D0A84FF), Color(0x2E5856D6)))), contentAlignment = Alignment.Center) {
        val b = bitmap
        if (b != null && !CoverImagePolicy.isPlaceholder(url)) Image(b, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.Outlined.LiveTv, null, Modifier.size(iconSize), tint = LocalShelfColors.current.secondaryText)
    }
}

/** «+1»: tap marks the next episode; a long press offers +2, +3, +5 or «до серии N». */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun IncrementButton(entry: Entry, modifier: Modifier = Modifier, onDark: Boolean = false) {
    val store = rememberStore()
    val haptics = LocalHapticFeedback.current
    val prefs = rememberSnapshot().preferences
    var pulse by remember { mutableStateOf(false) }
    val scale by animateFloatAsState(if (pulse) 1.18f else 1f, spring(dampingRatio = 0.5f), finishedListener = { pulse = false }, label = "pulse")
    var menu by remember { mutableStateOf(false) }
    var askTarget by remember { mutableStateOf(false) }
    Box(modifier) {
        Box(
            Modifier.scale(scale).size(52.dp)
                .then(if (onDark) Modifier.glass(CircleShape) else Modifier.clip(CircleShape).background(LocalShelfColors.current.surfaceHigh).border(0.8.dp, Color(0x1FFFFFFF), CircleShape))
                .combinedClickable(
                    enabled = entry.episode < 1_000_000,
                    onClick = {
                        if (store.increment(entry.id) != null) { pulse = true; if (prefs.haptics) haptics.performHapticFeedback(HapticFeedbackType.LongPress) }
                    },
                    onLongClick = { menu = true },
                )
                .semantics { contentDescription = "Следующая серия: ${entry.title}. Сейчас просмотрена серия ${entry.episode}" },
            contentAlignment = Alignment.Center,
        ) { Text("+1", color = Accent, fontWeight = FontWeight.Bold, fontSize = 19.sp) }
        DropdownMenu(menu, { menu = false }) {
            for (n in listOf(2, 3, 5)) DropdownMenuItem({ Text("+$n ${episodesWord(n)}") }, { menu = false; store.increment(entry.id, n) })
            DropdownMenuItem({ Text("До серии…") }, { menu = false; askTarget = true })
        }
    }
    if (askTarget) {
        var target by remember { mutableStateOf((entry.episode + 1).toString()) }
        AlertDialog(
            onDismissRequest = { askTarget = false },
            title = { Text("До какой серии отметить?") },
            text = {
                Column {
                    Text("Сейчас отмечена серия ${entry.episode}. Можно только увеличить номер; уменьшить — в «Изменить».", style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.height(12.dp))
                    IosTextField(target, { target = it.filter(Char::isDigit).take(7) }, singleLine = true, label = { Text("Номер серии") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
            },
            confirmButton = { TextButton({ target.toIntOrNull()?.let { if (it > entry.episode) store.increment(entry.id, it - entry.episode) }; askTarget = false }) { Text("Отметить") } },
            dismissButton = { TextButton({ askTarget = false }) { Text("Отмена") } },
        )
    }
}

@Composable
fun FilterChipPill(title: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = LocalShelfColors.current
    Box(
        modifier.clip(CircleShape)
            .background(if (selected) Accent.copy(alpha = 0.18f) else colors.primaryText.copy(alpha = 0.07f))
            .border(1.dp, if (selected) Accent.copy(alpha = 0.5f) else Color.Transparent, CircleShape)
            .clickable(onClick = onClick).heightIn(min = 40.dp).padding(horizontal = 15.dp),
        contentAlignment = Alignment.Center,
    ) { Text(title, color = if (selected) Accent else colors.primaryText, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, fontSize = 15.sp) }
}

@Composable
fun RatingStars(rating: Int?, onChange: (Int?) -> Unit, size: Dp = 30.dp) {
    Row(Modifier.semantics { contentDescription = "Моя оценка: " + (rating?.let { "$it из 5" } ?: "без оценки") }) {
        for (star in 1..5) {
            Icon(if (star <= (rating ?: 0)) Icons.Filled.Star else Icons.Filled.StarBorder, null, tint = Gold,
                modifier = Modifier.size(size + 8.dp).clip(CircleShape).clickable { onChange(if (rating == star) null else star) }.padding(4.dp))
        }
    }
}

@Composable
fun WeekdayPicker(days: List<Int>, onChange: (List<Int>) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.fillMaxWidth()) {
        for (day in ReleasePlanner.displayOrder) {
            val selected = day in days
            Box(
                Modifier.weight(1f).height(40.dp).clip(CircleShape)
                    .background(if (selected) Accent.copy(alpha = 0.2f) else LocalShelfColors.current.primaryText.copy(alpha = 0.08f))
                    .clickable { onChange(if (selected) days - day else (days + day).sorted()) }
                    .semantics { contentDescription = ReleasePlanner.fullNames[day - 1] + if (selected) ", выбрано" else "" },
                contentAlignment = Alignment.Center,
            ) { Text(ReleasePlanner.shortName(day), color = if (selected) Accent else LocalShelfColors.current.primaryText, fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal) }
        }
    }
}

@Composable
fun ProgressLine(value: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.28f))) {
        Box(Modifier.fillMaxWidth(value.coerceIn(0.03, 1.0).toFloat()).fillMaxHeight().clip(CircleShape).background(Accent))
    }
}

@Composable
fun CoverBadge(icon: ImageVector, tint: Color) {
    Box(Modifier.size(26.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.6f)), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(15.dp))
    }
}

@Composable
fun ScreenTopBar(title: String, onBack: (() -> Unit)?, actions: @Composable RowScope.() -> Unit = {}) {
    // iOS inline navigation bar: round glass back button, centred title, glass actions on the right.
    Box(Modifier.fillMaxWidth().statusBarsPadding().height(TopBarHeight).padding(horizontal = 14.dp)) {
        Text(title, Modifier.align(Alignment.Center).padding(horizontal = 104.dp), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (onBack != null) GlassIconButton(Icons.Filled.ArrowBackIosNew, "Назад", onBack, Modifier.align(Alignment.CenterStart))
        Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
    }
}

@Composable
fun Card(modifier: Modifier = Modifier, padding: Dp = 16.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(LocalShelfColors.current.surface).padding(padding), content = content)
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) =
    Text(text, modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp), color = LocalShelfColors.current.secondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)

@Composable
fun Footnote(text: String, modifier: Modifier = Modifier, color: Color = LocalShelfColors.current.secondaryText) =
    Text(text, modifier, color = color, style = MaterialTheme.typography.bodySmall)

@Composable
fun SwitchRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit, subtitle: String? = null, enabled: Boolean = true) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = if (enabled) LocalShelfColors.current.primaryText else LocalShelfColors.current.secondaryText)
            subtitle?.let { Footnote(it) }
        }
        Spacer(Modifier.width(10.dp))
        IosSwitch(checked, null, enabled)
    }
}

@Composable
fun NavRow(title: String, icon: ImageVector? = null, value: String? = null, color: Color = LocalShelfColors.current.primaryText, chevron: Boolean = false, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, tint = Accent, modifier = Modifier.size(22.dp)); Spacer(Modifier.width(14.dp)) }
        Text(title, Modifier.weight(1f), color = color, fontSize = 17.sp)
        value?.let { Text(it, color = LocalShelfColors.current.secondaryText, fontSize = 17.sp) }
        if (chevron) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, Modifier.size(24.dp), tint = LocalShelfColors.current.secondaryText.copy(alpha = 0.7f))
    }
}

@Composable
fun TagChips(tags: List<String>) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        tags.forEach { Text("#$it", Modifier.clip(CircleShape).background(LocalShelfColors.current.primaryText.copy(alpha = 0.12f)).padding(horizontal = 10.dp, vertical = 6.dp), fontSize = 12.sp) }
    }
}
