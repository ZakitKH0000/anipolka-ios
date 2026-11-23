package com.zakitkh.anipolka.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.zakitkh.anipolka.core.Preferences
import com.zakitkh.anipolka.core.Theme

/** Colours of the iOS design: near-black background, grouped surfaces, system blue accent. */
@Immutable
data class ShelfColors(
    val background: Color,
    val surface: Color,
    val surfaceHigh: Color,
    val primaryText: Color,
    val secondaryText: Color,
    val separator: Color,
    val dark: Boolean,
)

val Accent = Color(0xFF0A84FF)
val Orange = Color(0xFFFF9F0A)
val Gold = Color(0xFFFFD60A)
val Danger = Color(0xFFFF453A)
val Success = Color(0xFF30D158)

val LocalShelfColors = staticCompositionLocalOf {
    ShelfColors(Color(0xFF0B0D10), Color(0xFF1C1C1E), Color(0xFF2C2C2E), Color.White, Color(0xFF98989F), Color(0x33FFFFFF), true)
}

@Composable
fun AniPolkaTheme(preferences: Preferences, content: @Composable () -> Unit) {
    val dark = when (preferences.theme) { Theme.DARK -> true; Theme.LIGHT -> false; Theme.SYSTEM -> isSystemInDarkTheme() }
    val colors = if (dark) ShelfColors(
        background = if (preferences.pureBlack) Color.Black else Color(0xFF09090B),
        surface = Color(0xFF1C1C1E), surfaceHigh = Color(0xFF2C2C2E), primaryText = Color.White,
        secondaryText = Color(0xFF98989F), separator = Color(0x33FFFFFF), dark = true,
    ) else ShelfColors(
        background = Color(0xFFF2F2F7), surface = Color.White, surfaceHigh = Color(0xFFE9E9EE), primaryText = Color(0xFF111114),
        secondaryText = Color(0xFF6C6C72), separator = Color(0x22000000), dark = false,
    )
    val scheme = if (dark) darkColorScheme(
        primary = Accent, onPrimary = Color.White, primaryContainer = Accent.copy(alpha = 0.2f), onPrimaryContainer = Accent,
        secondaryContainer = Accent.copy(alpha = 0.2f), onSecondaryContainer = Accent, background = colors.background, surface = colors.surface,
        surfaceVariant = colors.surfaceHigh, onBackground = colors.primaryText, onSurface = colors.primaryText,
        onSurfaceVariant = colors.secondaryText, secondary = Accent, tertiary = Orange, error = Danger,
        surfaceContainer = colors.surface, surfaceContainerHigh = colors.surfaceHigh, surfaceContainerHighest = colors.surfaceHigh,
        outline = colors.separator, outlineVariant = colors.separator,
    ) else lightColorScheme(
        primary = Accent, onPrimary = Color.White, primaryContainer = Accent.copy(alpha = 0.2f), onPrimaryContainer = Accent,
        secondaryContainer = Accent.copy(alpha = 0.2f), onSecondaryContainer = Accent, background = colors.background, surface = colors.surface,
        surfaceVariant = colors.surfaceHigh, onBackground = colors.primaryText, onSurface = colors.primaryText,
        onSurfaceVariant = colors.secondaryText, secondary = Accent, tertiary = Orange, error = Danger,
        surfaceContainer = colors.surface, surfaceContainerHigh = colors.surfaceHigh, surfaceContainerHighest = colors.surfaceHigh,
        outline = colors.separator, outlineVariant = colors.separator,
    )
    androidx.compose.runtime.CompositionLocalProvider(LocalShelfColors provides colors) {
        // iOS-like text: no extra letter spacing and line height proportional to the size.
        val base = androidx.compose.material3.Typography()
        fun androidx.compose.ui.text.TextStyle.ios() = copy(lineHeight = 1.3.em, letterSpacing = 0.sp)
        val typography = base.copy(
            bodyLarge = base.bodyLarge.ios(), bodyMedium = base.bodyMedium.ios(), bodySmall = base.bodySmall.ios(),
            titleLarge = base.titleLarge.ios(), titleMedium = base.titleMedium.ios(), titleSmall = base.titleSmall.ios(),
            labelLarge = base.labelLarge.ios(), labelMedium = base.labelMedium.ios(), labelSmall = base.labelSmall.ios(),
        )
        MaterialTheme(colorScheme = scheme, typography = typography) {
            // Screens outside a Scaffold would otherwise draw black text on the dark background.
            androidx.compose.runtime.CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides colors.primaryText, content = content)
        }
    }
}
