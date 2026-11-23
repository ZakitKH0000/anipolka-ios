package com.zakitkh.anipolka.ui

import android.app.TimePickerDialog
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.ui.platform.LocalDensity
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.BuildConfig
import com.zakitkh.anipolka.R
import com.zakitkh.anipolka.core.*
import com.zakitkh.anipolka.data.ShelfAssistant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

/** Face ID's Android counterpart: biometrics or the device PIN, provided by the activity. */
interface AppLockControl {
    val available: Boolean
    fun authenticate(reason: String, onResult: (Boolean) -> Unit)
}
val LocalAppLock = staticCompositionLocalOf<AppLockControl> { object : AppLockControl { override val available = false; override fun authenticate(reason: String, onResult: (Boolean) -> Unit) = onResult(false) } }

object AppIcons {
    data class Variant(val alias: String, val title: String, val preview: Int)
    val variants = listOf(
        Variant(".LauncherDefault", "Синяя", R.mipmap.ic_launcher_preview),
        Variant(".LauncherLight", "Светлая", R.mipmap.ic_launcher_light_preview),
        Variant(".LauncherDonghua", "Дунхуа", R.mipmap.ic_launcher_donghua_preview),
    )
    private fun component(context: Context, alias: String) = ComponentName(context.packageName, "com.zakitkh.anipolka$alias")
    fun current(context: Context): String = variants.firstOrNull { v ->
        val state = context.packageManager.getComponentEnabledSetting(component(context, v.alias))
        state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED || (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && v.alias == ".LauncherDefault")
    }?.alias ?: ".LauncherDefault"
    fun set(context: Context, alias: String) {
        val pm = context.packageManager
        // Enable the new launcher entry first, so the app never disappears from the home screen.
        pm.setComponentEnabledSetting(component(context, alias), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        variants.filter { it.alias != alias }.forEach {
            pm.setComponentEnabledSetting(component(context, it.alias), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP)
        }
    }
}

@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val store = rememberStore()
    val snapshot by store.snapshot.collectAsState()
    val navigator = LocalNavigator.current
    val assistant = remember { ShelfAssistant.get(context) }
    val finding by assistant.findingCovers.collectAsState()
    val lock = LocalAppLock.current
    val scope = rememberCoroutineScope()
    val prefs = snapshot.preferences
    var notice by remember { mutableStateOf<String?>(null) }
    var permissionNote by remember { mutableStateOf<String?>(null) }
    var backup by remember { mutableStateOf<Snapshot?>(null) }
    var confirmReplace by remember { mutableStateOf(false) }
    var iconAlias by remember { mutableStateOf(AppIcons.current(context)) }

    val askForReleases = rememberNotificationPermission { allowed ->
        store.setPreferences { it.copy(releaseNotifications = allowed) }
        permissionNote = if (allowed) "Уведомления включены для новых серий выбранных источников." else "Уведомления не разрешены. Их можно включить в настройках Android → Приложения → АниПолка → Уведомления."
    }
    val askForDigest = rememberNotificationPermission { allowed ->
        store.setPreferences { it.copy(dailyDigest = allowed) }
        if (!allowed) permissionNote = "Уведомления не разрешены. Их можно включить в настройках Android → Приложения → АниПолка → Уведомления."
    }
    val askForAiring = rememberNotificationPermission { allowed ->
        store.setPreferences { it.copy(airingReminders = allowed) }
        if (!allowed) permissionNote = "Уведомления не разрешены. Их можно включить в настройках Android → Приложения → АниПолка → Уведомления."
    }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            notice = try {
                val data = withContext(Dispatchers.Default) { store.current.encoded() }
                withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(data) } }
                "Резервная копия сохранена."
            } catch (e: Exception) { "Копия не сохранена: ${e.message}" }
        }
    }
    val restore = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        scope.launch {
            try {
                backup = withContext(Dispatchers.IO) {
                    val data = context.contentResolver.openInputStream(uri)?.use { input ->
                        val bytes = input.readBytes(); if (bytes.size > 150_000_000) throw ShelfError("Файл больше 150 МБ."); bytes
                    } ?: throw ShelfError("Файл не открылся.")
                    Snapshot.decode(data)
                }
            } catch (e: Exception) { notice = "Восстановление не выполнено: ${e.message}" }
        }
    }

    val scroll = rememberScrollState()
    val haze = rememberHazeState()
    val density = LocalDensity.current
    val collapsed by remember { derivedStateOf { scroll.value > with(density) { 44.dp.roundToPx() } } }
    val secondary = LocalShelfColors.current.secondaryText
    Box(Modifier.fillMaxSize()) {
    Column(
        Modifier.fillMaxSize().hazeSource(haze).verticalScroll(scroll)
            .padding(start = 16.dp, end = 16.dp, top = contentTopPadding(), bottom = contentBottomPadding()),
    ) {
        LargeTitle("Настройки")
        IosGroup(inset = 60.dp, footer = "Список историй, серии и итоги обычным текстом: для заметок, друга или ИИ-ассистента.") {
            IosRow("Итоги просмотра", icon = Icons.Filled.BarChart, chevron = true, onClick = { navigator.push(Route.Stats) })
            IosRow("Текст для копирования", icon = Icons.Filled.Description, chevron = true, onClick = { navigator.push(Route.Report) })
        }

        IosGroup(header = "Оформление") {
            IosPickerRow("Тема", Theme.entries.map { it.label }, prefs.theme.ordinal) { i -> store.setPreferences { it.copy(theme = Theme.entries[i]) } }
            IosPickerRow("Вид коллекции", Layout.entries.map { it.label }, prefs.layout.ordinal) { i -> store.setPreferences { it.copy(layout = Layout.entries[i]) } }
            IosPickerRow("Сортировка", ShelfSort.entries.map { it.raw }, prefs.sort.ordinal) { i -> store.setPreferences { it.copy(sort = ShelfSort.entries[i]) } }
            IosRow("Ручной порядок", titleColor = Accent, onClick = { navigator.push(Route.Reorder) })
            IosToggleRow("Продолжить просмотр", prefs.showContinue, { v -> store.setPreferences { it.copy(showContinue = v) } })
            IosToggleRow("Группы по статусам", prefs.shelves, { v -> store.setPreferences { it.copy(shelves = v) } })
            IosToggleRow("Чисто чёрный фон (OLED)", prefs.pureBlack, { v -> store.setPreferences { it.copy(pureBlack = v) } })
            Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                Text("Иконка приложения", fontSize = 17.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp), modifier = Modifier.padding(top = 10.dp)) {
                    AppIcons.variants.forEach { v ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clip(RoundedCornerShape(14.dp)).clickable { AppIcons.set(context, v.alias); iconAlias = v.alias }) {
                            Image(painterResource(v.preview), v.title, Modifier.size(58.dp).clip(RoundedCornerShape(14.dp))
                                .border(3.dp, if (iconAlias == v.alias) Accent else Color.Transparent, RoundedCornerShape(14.dp)))
                            Text(v.title, color = if (iconAlias == v.alias) Accent else LocalShelfColors.current.primaryText, fontSize = 12.sp, modifier = Modifier.padding(top = 5.dp))
                        }
                    }
                }
                Text("Лаунчер может обновить значок через несколько секунд.", color = secondary, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
            }
        }

        IosGroup(header = "Отклик и сеть", footer = "Сохранённые обложки доступны офлайн. Ограничение Wi-Fi действует на все загружаемые изображения, в том числе результаты поиска. Поиск названий использует любую сеть.") {
            IosToggleRow("Тактильный отклик при +1", prefs.haptics, { v -> store.setPreferences { it.copy(haptics = v) } })
            IosToggleRow("Обложки только через Wi-Fi", prefs.wifiOnly, { v -> store.setPreferences { it.copy(wifiOnly = v) } })
        }

        val days = ReleasePlanner.displayOrder.mapNotNull { d -> ReleasePlanner.due(snapshot.entries, d).size.takeIf { it > 0 }?.let { "${ReleasePlanner.shortName(d)} — $it" } }
        IosGroup(header = "Дни выхода", footer = "Одно уведомление в выбранное время в дни, отмеченные в карточках. Его ставит сам телефон: интернет и сервер не нужны. Android может доставить его с задержкой в несколько минут.") {
            IosToggleRow("Сводка в дни выхода", prefs.dailyDigest, { v -> if (v) askForDigest() else store.setPreferences { it.copy(dailyDigest = false) } })
            if (prefs.dailyDigest) IosRow("Время сводки", onClick = {
                TimePickerDialog(context, { _, h, m -> store.setPreferences { it.copy(digestMinutes = h * 60 + m) } }, prefs.digestMinutes / 60, prefs.digestMinutes % 60, true).show()
            }, trailing = { ValueChip("%02d:%02d".format(prefs.digestMinutes / 60, prefs.digestMinutes % 60)) })
            Text(if (days.isEmpty()) "Дни выхода ещё не указаны. Откройте историю → «Изменить» → «Дни выхода и метки»." else "По дням: " + days.joinToString(", "),
                Modifier.padding(horizontal = 16.dp, vertical = 12.dp), color = secondary, fontSize = 15.sp)
        }

        IosGroup(header = "Виджет и быстрые действия", inset = 60.dp) {
            IosRow("Виджет «Продолжить просмотр»", icon = Icons.Filled.Widgets, subtitle = "Удерживайте пустое место на главном экране → Виджеты → АниПолка.")
            IosRow("Плитка «+1 серия» в шторке", icon = Icons.Filled.ToggleOn, subtitle = "Откройте шторку → карандаш (изменить) → перетащите плитку АниПолки.")
            IosRow("Ярлыки и «Поделиться»", icon = Icons.Filled.TouchApp, subtitle = "Удерживайте значок: «+1 серия» и «Добавить историю». Ссылку из браузера можно отправить через «Поделиться → АниПолка».")
        }

        IosGroup(header = "Автообложки", footer = "Обложка сохраняется при единственном точном совпадении названия. Ваше название и прогресс не меняются. Свои обложки и явно убранные изображения не заменяются.") {
            IosToggleRow("Автоматически искать обложки", prefs.automaticCovers, { v -> store.setPreferences { it.copy(automaticCovers = v) }; if (v) assistant.queueCovers(true) })
            IosRow("Найти недостающие обложки", titleColor = Accent, enabled = !finding, onClick = { assistant.queueCovers(true) },
                trailing = if (finding) ({ CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) }) else null)
        }

        IosGroup(header = "Новые серии", footer = "В карточке истории выберите страницу AniVibe, сезон и озвучку. Время фоновой проверки назначает Android: мгновенные уведомления без сервера не гарантируются. Кнопка «Проверить сейчас» — во вкладке «Серии».") {
            IosToggleRow("Фоновые проверки серий", prefs.backgroundChecks, { v -> store.setPreferences { it.copy(backgroundChecks = v) } })
            IosToggleRow("Уведомлять о новых сериях", prefs.releaseNotifications, { v -> if (v) askForReleases() else store.setPreferences { it.copy(releaseNotifications = false) } })
            IosToggleRow("Даты выхода из Shikimori", prefs.catalogUpdates, { v -> store.setPreferences { it.copy(catalogUpdates = v) } },
                subtitle = "Время следующей серии, сколько вышло, продолжения")
            IosToggleRow("Напоминать о выходе серии", prefs.airingReminders, { v -> if (v) askForAiring() else store.setPreferences { it.copy(airingReminders = false) } },
                enabled = prefs.catalogUpdates, subtitle = "Уведомление в момент показа по расписанию")
            permissionNote?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 12.dp), color = secondary, fontSize = 15.sp) }
        }

        IosGroup(header = "Конфиденциальность", footer = "Коллекция закрывается при уходе из приложения и скрывается в списке недавних. Виджет и уведомления показывают названия и без разблокировки.") {
            IosToggleRow("Блокировка отпечатком или PIN", prefs.appLock, { v ->
                if (v && !lock.available) { permissionNote = null; notice = "На телефоне не настроены отпечаток или PIN, поэтому блокировка недоступна." }
                else lock.authenticate(if (v) "Включить блокировку АниПолки" else "Выключить блокировку АниПолки") { ok -> if (ok) store.setPreferences { it.copy(appLock = v) } }
            })
        }

        IosGroup(header = "Перенос и резервная копия", inset = 60.dp, footer = "Копия содержит коллекцию, прогресс, порядок, настройки и сохранённые обложки. Формат совпадает с iPhone-версией: копию можно перенести между телефонами в обе стороны.") {
            IosRow("Импорт текстового списка", icon = Icons.Filled.PlaylistAdd, titleColor = Accent, onClick = { navigator.push(Route.Import) })
            IosRow("Сохранить копию в файл", icon = Icons.Filled.Upload, titleColor = Accent, onClick = { export.launch("АниПолка-${LocalDate.now()}.json") })
            IosRow("Восстановить из файла", icon = Icons.Filled.Download, titleColor = Accent, onClick = { restore.launch(arrayOf("application/json", "application/octet-stream", "*/*")) })
            notice?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 12.dp), color = secondary, fontSize = 15.sp) }
        }

        IosGroup(header = "Об АниПолке", inset = 60.dp, footer = "Коллекция хранится на телефоне. Без рекламы и аналитики. Для поиска обложек название истории отправляется в Shikimori или Kitsu. Проверка серий читает только выбранные вами публичные страницы источников.") {
            IosRow("АниПолка ${BuildConfig.VERSION_NAME}", icon = Icons.Filled.CollectionsBookmark, subtitle = "Разработчик — Закир Халилов · для личного использования")
            IosRow("Каталог и изображения: Shikimori", icon = Icons.Filled.Public, titleColor = Accent, onClick = { openUrl(context, "https://shikimori.io") })
            IosRow("Дополнительные обложки: Kitsu", icon = Icons.Filled.Image, titleColor = Accent, onClick = { openUrl(context, "https://kitsu.app") })
        }
    }
    GlassTopBar("Настройки", collapsed, haze)
    }

    backup?.let { copy ->
        AlertDialog({ backup = null }, title = { Text("Восстановление") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Произведений: ${copy.entries.size}")
                    Text("Сохранённых обложек: ${copy.entries.count { it.coverData != null }}")
                    Footnote("В вашей коллекции сейчас: ${snapshot.entries.size}")
                    Footnote("«Объединить» добавит записи с новыми идентификаторами; текущие записи и настройки сохранятся. «Заменить» заменит коллекцию и настройки.")
                }
            },
            confirmButton = { TextButton({ if (store.restore(copy, false)) { backup = null; notice = "Коллекции объединены." } }, enabled = store.loadFailure == null) { Text("Объединить") } },
            dismissButton = { Row { TextButton({ confirmReplace = true }) { Text("Заменить", color = Danger) }; TextButton({ backup = null }) { Text("Отмена") } } })
    }
    if (confirmReplace) AlertDialog({ confirmReplace = false }, title = { Text("Заменить текущую коллекцию?") },
        text = { Text("Текущий прогресс будет заменён данными выбранной копии. Перед заменой желательно сохранить отдельную копию.") },
        confirmButton = { TextButton({ confirmReplace = false; backup?.let { if (store.restore(it, true)) { backup = null; notice = "Коллекция восстановлена вместе с настройками." } } }) { Text("Заменить", color = Danger) } },
        dismissButton = { TextButton({ confirmReplace = false }) { Text("Отмена") } })
}
