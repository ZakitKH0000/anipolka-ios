package com.zakitkh.anipolka.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.R
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.zakitkh.anipolka.core.Snapshot
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.UUID

sealed interface Route {
    data class Detail(val id: UUID) : Route
    data class Editor(val id: UUID) : Route
    data object Wizard : Route
    data class Sources(val id: UUID, val initial: String? = null) : Route
    data object Week : Route
    data object Stats : Route
    data object Report : Route
    data class History(val id: UUID) : Route
    data object Import : Route
    data object Reorder : Route
    data object Suggestion : Route
    data class LinkInbox(val url: String) : Route
}

class Navigator {
    val stack = mutableStateListOf<Route>()
    fun push(route: Route) { stack.add(route) }
    fun pop() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    fun popTo(predicate: (Route) -> Boolean) { while (stack.isNotEmpty() && !predicate(stack.last())) stack.removeAt(stack.lastIndex) }
}

val LocalNavigator = staticCompositionLocalOf { Navigator() }

/** Requests coming from outside the UI: widget rows, shortcuts, the share sheet. */
sealed interface AppRequest {
    data class OpenEntry(val id: UUID) : AppRequest
    data object Add : AppRequest
    data class SharedLink(val url: String) : AppRequest
}

@Composable
fun AppRoot(requests: MutableStateFlow<AppRequest?>, locked: Boolean, onUnlock: () -> Unit) {
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = remember { Navigator() }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val request by requests.collectAsState()
    val saved = rememberSaveableStateHolder()
    LaunchedEffect(request) {
        when (val r = request) {
            is AppRequest.OpenEntry -> if (snapshot.entry(r.id) != null) { navigator.stack.clear(); tab = 0; navigator.push(Route.Detail(r.id)) }
            AppRequest.Add -> { navigator.stack.clear(); tab = 0; navigator.push(Route.Wizard) }
            is AppRequest.SharedLink -> navigator.push(Route.LinkInbox(r.url))
            null -> {}
        }
        requests.value = null
    }
    AniPolkaTheme(snapshot.preferences) {
        CompositionLocalProvider(LocalNavigator provides navigator) {
            val colors = LocalShelfColors.current
            Box(Modifier.fillMaxSize().background(colors.background)) {
                val depth = navigator.stack.size
                val top = navigator.stack.lastOrNull()
                if (top != null) BackHandler { navigator.pop() }
                // iOS push: the new screen slides in from the right over a dimmed, slightly shifted previous one.
                AnimatedContent(
                    targetState = depth to top,
                    contentKey = { "${it.first}:${it.second}" },
                    transitionSpec = {
                        val forward = targetState.first > initialState.first
                        val spec = tween<IntOffset>(380, easing = FastOutSlowInEasing)
                        val fade = tween<Float>(380)
                        (if (forward) slideInHorizontally(spec) { it } togetherWith (slideOutHorizontally(spec) { -it / 4 } + fadeOut(fade, 0.6f))
                        else (slideInHorizontally(spec) { -it / 4 } + fadeIn(fade, 0.6f)) togetherWith slideOutHorizontally(spec) { it })
                            .apply { targetContentZIndex = if (forward) 1f else -1f }
                    },
                    label = "stack",
                ) { (level, route) ->
                    saved.SaveableStateProvider("$level:$route") {
                        Box(Modifier.fillMaxSize().background(colors.background)) {
                            if (route == null) Tabs(tab, { tab = it }, snapshot) else RouteScreen(route)
                        }
                    }
                }
                UndoBar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = if (top == null) 82.dp else 16.dp))
                ErrorDialog()
                if (locked && snapshot.preferences.appLock) LockScreen(onUnlock)
            }
        }
    }
}

@Composable
private fun Tabs(tab: Int, onTab: (Int) -> Unit, snapshot: Snapshot) {
    val unread = snapshot.entries.sumOf { e -> e.releaseNotices.count { !it.read } }
    val haze = rememberHazeState()
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().hazeSource(haze)) {
            CompositionLocalProvider(LocalTabBarSpace provides 74.dp) {
                Crossfade(tab, animationSpec = tween(200), label = "tab") { t ->
                    when (t) {
                        0 -> CollectionScreen()
                        1 -> ReleasesScreen()
                        else -> SettingsScreen()
                    }
                }
            }
        }
        CompositionLocalProvider(LocalHazeState provides haze) {
            GlassTabBar(
                listOf(
                    TabItem("Коллекция", painterResource(R.drawable.ic_stat_shelf)),
                    TabItem("Серии", rememberTabIcon(Icons.Filled.Notifications), unread),
                    TabItem("Настройки", rememberTabIcon(Icons.Filled.Tune)),
                ),
                tab, onTab, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 8.dp),
            )
        }
    }
}

@Composable
private fun RouteScreen(route: Route) {
    when (route) {
        is Route.Detail -> EntryDetailScreen(route.id)
        is Route.Editor -> EntryEditorScreen(route.id)
        Route.Wizard -> AddWizardScreen()
        is Route.Sources -> EntrySourcesScreen(route.id, route.initial)
        Route.Week -> WeekScreen()
        Route.Stats -> StatsScreen()
        Route.Report -> ReportScreen()
        is Route.History -> TitleHistoryScreen(route.id)
        Route.Import -> TextImportScreen()
        Route.Reorder -> ReorderScreen()
        Route.Suggestion -> SuggestionScreen()
        is Route.LinkInbox -> LinkInboxScreen(route.url)
    }
}

@Composable
private fun UndoBar(modifier: Modifier) {
    val store = rememberStore()
    val token by store.undo.collectAsState()
    val t = token ?: return
    Row(
        modifier.padding(horizontal = 22.dp).fillMaxWidth().height(52.dp).glass(CircleShape).padding(start = 20.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Серия ${t.applied.episode} отмечена", Modifier.weight(1f), fontSize = 15.sp)
        TextButton({ store.undoLast() }) { Text("Отменить", fontWeight = FontWeight.Bold, color = Accent) }
    }
}

@Composable
private fun ErrorDialog() {
    val store = rememberStore()
    val error by store.error.collectAsState()
    val e = error ?: return
    AlertDialog({ store.error.value = null }, confirmButton = { TextButton({ store.error.value = null }) { Text("Понятно") } },
        title = { Text("Не удалось выполнить действие") }, text = { Text(e) })
}

@Composable
private fun LockScreen(onUnlock: () -> Unit) {
    LaunchedEffect(Unit) { onUnlock() }
    Column(Modifier.fillMaxSize().background(LocalShelfColors.current.background), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(Icons.Filled.Lock, null, tint = Accent, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(16.dp))
        Text("АниПолка заблокирована", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(16.dp))
        Button(onUnlock) { Text("Разблокировать") }
    }
}
