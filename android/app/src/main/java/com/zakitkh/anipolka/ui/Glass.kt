package com.zakitkh.anipolka.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBackIosNew
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect

/*
 * iOS 26 "Liquid Glass" pieces: a floating capsule tab bar, round glass buttons, a title bar that blurs
 * the content scrolling under it, and grouped inset lists with iOS switches and pickers.
 * The blur needs Android 12+; older phones get a solid tinted glass instead.
 */

/** The content the glass in this part of the screen blurs; null means a tinted fallback without blur. */
val LocalHazeState = staticCompositionLocalOf<HazeState?> { null }

/** Space the floating tab bar takes at the bottom; screens pad their scrolling content by it. */
val LocalTabBarSpace = staticCompositionLocalOf { 0.dp }

@Composable
fun contentBottomPadding(extra: Dp = 24.dp): Dp =
    WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + LocalTabBarSpace.current + extra

@Composable
fun contentTopPadding(): Dp = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + TopBarHeight

val TopBarHeight = 54.dp

@Composable
fun glassStyle(strong: Boolean = false): HazeStyle {
    val c = LocalShelfColors.current
    val tint = if (c.dark) (if (strong) c.background.copy(alpha = 0.8f) else Color(0xFF1E1E22).copy(alpha = 0.5f))
    else Color.White.copy(alpha = if (strong) 0.8f else 0.6f)
    return HazeStyle(
        backgroundColor = c.background,
        tints = listOf(HazeTint(tint)),
        blurRadius = if (strong) 30.dp else 22.dp,
        noiseFactor = 0.03f,
        fallbackTint = HazeTint(if (c.dark) Color(0xF0222226) else Color(0xF5FAFAFC)),
    )
}

/** Blurred, tinted glass with a light rim and a soft highlight on top. */
@Composable
fun Modifier.glass(shape: Shape, state: HazeState? = LocalHazeState.current, shadow: Boolean = true, strong: Boolean = false): Modifier {
    val c = LocalShelfColors.current
    val style = glassStyle(strong)
    val shadowed = if (shadow) this.shadow(10.dp, shape, ambientColor = Color.Black.copy(alpha = 0.25f), spotColor = Color.Black.copy(alpha = 0.35f)) else this
    val clipped = shadowed.clip(shape)
    val blurred = if (state != null) clipped.hazeEffect(state, style) else clipped.background(if (c.dark) Color(0xF0222226) else Color(0xF5FAFAFC))
    val rim = if (c.dark) listOf(Color.White.copy(alpha = 0.30f), Color.White.copy(alpha = 0.06f), Color.White.copy(alpha = 0.14f))
    else listOf(Color.White.copy(alpha = 0.95f), Color.Black.copy(alpha = 0.06f), Color.Black.copy(alpha = 0.08f))
    return blurred
        .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = if (c.dark) 0.07f else 0.25f), Color.Transparent)))
        .border(0.8.dp, Brush.verticalGradient(rim), shape)
}

/** Press feedback of glass controls: a short squeeze, like iOS. */
@Composable
private fun pressScale(source: MutableInteractionSource): Float {
    val pressed by source.collectIsPressedAsState()
    return animateFloatAsState(if (pressed) 0.9f else 1f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMediumLow), label = "press").value
}

@Composable
fun GlassIconButton(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = LocalShelfColors.current.primaryText, size: Dp = 46.dp) {
    val source = remember { MutableInteractionSource() }
    Box(
        modifier.scale(pressScale(source)).size(size).glass(CircleShape)
            .clickable(source, null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, Modifier.size(22.dp), tint = tint) }
}

/** A capsule text button; `prominent` is the filled blue confirm button of iOS sheets. */
@Composable
fun GlassTextButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, prominent: Boolean = false, color: Color = LocalShelfColors.current.primaryText) {
    val source = remember { MutableInteractionSource() }
    val shape = CircleShape
    val base = modifier.scale(pressScale(source)).height(46.dp).alpha(if (enabled) 1f else 0.45f)
    Box(
        (if (prominent) base.shadow(10.dp, shape, spotColor = Accent.copy(alpha = 0.5f)).clip(shape).background(Accent)
            .border(0.8.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.45f), Color.Transparent)), shape)
        else base.glass(shape))
            .clickable(source, null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = if (prominent) Color.White else color, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1) }
}

/**
 * The navigation bar: round glass buttons always float; once the large title scrolls away, the small
 * centred title fades in over a blur of the content that fades out towards the bottom edge.
 */
@Composable
fun GlassTopBar(
    title: String,
    collapsed: Boolean,
    state: HazeState?,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val c = LocalShelfColors.current
    val progress by animateFloatAsState(if (collapsed) 1f else 0f, label = "bar")
    Box(modifier.fillMaxWidth()) {
        if (progress > 0.01f) {
            val fade = Brush.verticalGradient(0f to Color.Black, 0.82f to Color.Black, 1f to Color.Transparent)
            Box(
                Modifier.matchParentSize().padding(bottom = 0.dp).then(
                    if (state != null) Modifier.hazeEffect(state, glassStyle(strong = true)) { alpha = progress; mask = fade }
                    else Modifier.alpha(progress).background(Brush.verticalGradient(listOf(c.background, c.background.copy(alpha = 0.92f), Color.Transparent)))
                )
            )
        }
        CompositionLocalProvider(LocalHazeState provides state) {
            Box(Modifier.fillMaxWidth().statusBarsPadding().height(TopBarHeight).padding(horizontal = 14.dp)) {
                Text(
                    title, Modifier.align(Alignment.Center).padding(horizontal = 96.dp).alpha(progress),
                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                )
                if (onBack != null) GlassIconButton(Icons.Filled.ArrowBackIosNew, "Назад", onBack, Modifier.align(Alignment.CenterStart), size = 46.dp)
                Row(Modifier.align(Alignment.CenterEnd), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically, content = actions)
            }
        }
        // Keeps the bar's own blur area a little taller than the buttons, so the fade has room.
        Spacer(Modifier.fillMaxWidth().statusBarsPadding().height(TopBarHeight + 10.dp))
    }
}

/** iOS large title with an optional subtitle line under it. */
@Composable
fun LargeTitle(title: String, subtitle: String? = null, modifier: Modifier = Modifier) {
    Column(modifier.padding(start = 4.dp, top = 2.dp, bottom = 6.dp)) {
        Text(title, fontSize = 34.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp, lineHeight = 40.sp)
        if (!subtitle.isNullOrBlank()) Text(subtitle, color = LocalShelfColors.current.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(top = 2.dp))
    }
}

data class TabItem(val title: String, val icon: Painter, val badge: Int = 0)

@Composable
fun rememberTabIcon(icon: ImageVector): Painter = rememberVectorPainter(icon)

/**
 * The floating capsule tab bar. The highlight under the selected tab slides with a spring and the
 * pressed tab squeezes, so the bar feels like liquid glass rather than a static strip.
 */
@Composable
fun GlassTabBar(items: List<TabItem>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val c = LocalShelfColors.current
    BoxWithConstraints(modifier.padding(horizontal = 22.dp).fillMaxWidth().height(66.dp).glass(CircleShape).padding(4.dp)) {
        val itemWidth = maxWidth / items.size
        val offset by animateDpAsState(itemWidth * selected, spring(dampingRatio = 0.72f, stiffness = 380f), label = "pill")
        Box(
            Modifier.offset(x = offset).width(itemWidth).fillMaxHeight().clip(CircleShape)
                .background(if (c.dark) Color.White.copy(alpha = 0.13f) else Color.Black.copy(alpha = 0.07f))
        )
        Row(Modifier.fillMaxSize()) {
            items.forEachIndexed { index, item ->
                val source = remember { MutableInteractionSource() }
                val active = index == selected
                val tint by animateColorAsState(if (active) Accent else c.primaryText, label = "tab")
                Column(
                    Modifier.weight(1f).fillMaxHeight().scale(pressScale(source)).clip(CircleShape)
                        .clickable(source, null, role = Role.Tab) { onSelect(index) }
                        .semantics { this.selected = active; contentDescription = item.title + if (item.badge > 0) ", новых: ${item.badge}" else "" },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Box {
                        Icon(item.icon, null, Modifier.size(25.dp), tint = tint)
                        if (item.badge > 0) Text(
                            if (item.badge > 99) "99+" else "${item.badge}",
                            Modifier.align(Alignment.TopEnd).offset(x = 10.dp, y = (-5).dp).clip(CircleShape).background(Danger)
                                .defaultMinSize(minWidth = 17.dp).padding(horizontal = 4.dp, vertical = 1.dp),
                            color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, lineHeight = 14.sp,
                        )
                    }
                    Spacer(Modifier.height(3.dp))
                    Text(item.title, color = tint, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                }
            }
        }
    }
}

/** iOS switch: a 51×31 capsule with a white knob that slides with a spring. */
@Composable
fun IosSwitch(checked: Boolean, onChange: ((Boolean) -> Unit)?, enabled: Boolean = true) {
    val c = LocalShelfColors.current
    val progress by animateFloatAsState(if (checked) 1f else 0f, spring(dampingRatio = 0.7f, stiffness = 520f), label = "switch")
    val track = lerp(if (c.dark) Color(0xFF39393D) else Color(0xFFE3E3E8), Accent, progress)
    Box(
        Modifier.size(51.dp, 31.dp).alpha(if (enabled) 1f else 0.45f).clip(CircleShape).background(track)
            .then(if (onChange != null) Modifier.toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onChange) else Modifier)
            .padding(2.dp),
    ) {
        Box(Modifier.offset(x = 20.dp * progress).size(27.dp).shadow(3.dp, CircleShape).background(Color.White, CircleShape))
    }
}

/** A grouped inset list section: optional header, rounded card with inset separators, optional footer. */
@Composable
fun IosGroup(
    modifier: Modifier = Modifier,
    header: String? = null,
    footer: String? = null,
    inset: Dp = 16.dp,
    spaced: Boolean = true,
    content: @Composable () -> Unit,
) {
    val c = LocalShelfColors.current
    Column(modifier.fillMaxWidth()) {
        if (header != null) Text(header, Modifier.padding(start = 16.dp, end = 16.dp, top = 26.dp, bottom = 8.dp),
            color = c.secondaryText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        else if (spaced) Spacer(Modifier.height(20.dp))
        DividedColumn(Modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp)).background(c.surface), inset, c.separator, content)
        if (footer != null) Text(footer, Modifier.padding(start = 16.dp, end = 16.dp, top = 7.dp), color = c.secondaryText, fontSize = 13.sp, lineHeight = 17.sp)
    }
}

/** Stacks rows and draws a hairline between visible ones, starting at the text, like iOS lists. */
@Composable
private fun DividedColumn(modifier: Modifier, inset: Dp, color: Color, content: @Composable () -> Unit) {
    var lines by remember { mutableStateOf(IntArray(0)) }
    Layout(content, modifier.drawWithContent {
        drawContent()
        val start = inset.toPx()
        val stroke = maxOf(1f, 0.5.dp.toPx())
        lines.forEach { y -> drawLine(color, Offset(start, y.toFloat()), Offset(size.width, y.toFloat()), stroke) }
    }) { measurables, constraints ->
        val width = constraints.maxWidth
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = width, minHeight = 0, maxHeight = androidx.compose.ui.unit.Constraints.Infinity)) }
        layout(width, placeables.sumOf { it.height }) {
            var y = 0
            var seen = false
            val ys = ArrayList<Int>()
            placeables.forEach { p ->
                if (p.height > 0) { if (seen) ys.add(y); seen = true }
                p.placeRelative(0, y); y += p.height
            }
            val found = ys.toIntArray()
            if (!found.contentEquals(lines)) lines = found
        }
    }
}

/** A list row: optional blue icon, title, grey value, chevron for navigation or a custom trailing view. */
@Composable
fun IosRow(
    title: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    iconTint: Color = Accent,
    subtitle: String? = null,
    value: String? = null,
    chevron: Boolean = false,
    titleColor: Color = LocalShelfColors.current.primaryText,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val c = LocalShelfColors.current
    Row(
        modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier)
            .heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 10.dp).alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) { Icon(icon, null, Modifier.size(23.dp), tint = iconTint) }
            Spacer(Modifier.width(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, color = titleColor, fontSize = 17.sp, lineHeight = 22.sp)
            if (subtitle != null) Text(subtitle, color = c.secondaryText, fontSize = 13.sp, lineHeight = 17.sp, modifier = Modifier.padding(top = 2.dp))
        }
        if (value != null) Text(value, color = c.secondaryText, fontSize = 17.sp, maxLines = 1, modifier = Modifier.padding(start = 8.dp))
        trailing?.let { Spacer(Modifier.width(8.dp)); it() }
        if (chevron) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, Modifier.padding(start = 4.dp).size(24.dp), tint = c.secondaryText.copy(alpha = 0.7f))
    }
}

@Composable
fun IosToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit, subtitle: String? = null, enabled: Boolean = true, icon: ImageVector? = null) =
    IosRow(title, subtitle = subtitle, enabled = enabled, icon = icon, onClick = { onChange(!checked) }, trailing = { IosSwitch(checked, null, enabled) })

/** iOS menu picker: the current value in blue with ⌃⌄; a tap opens a menu with a checkmark. */
@Composable
fun IosPickerRow(title: String, options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val c = LocalShelfColors.current
    IosRow(title, onClick = { open = true }, trailing = {
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(options.getOrElse(selected) { "" }, color = Accent, fontSize = 17.sp, maxLines = 1)
                Icon(Icons.Filled.UnfoldMore, null, Modifier.size(18.dp), tint = Accent)
            }
            DropdownMenu(open, { open = false }, shape = RoundedCornerShape(18.dp), containerColor = c.surfaceHigh) {
                options.forEachIndexed { i, option ->
                    DropdownMenuItem({ Text(option, fontSize = 16.sp) }, { open = false; onSelect(i) },
                        leadingIcon = { Box(Modifier.width(20.dp)) { if (i == selected) Icon(Icons.Filled.Check, null, Modifier.size(18.dp)) } })
                }
            }
        }
    })
}

/** Grey rounded value chip on the right of a row, like the time in an iOS date picker. */
@Composable
fun ValueChip(text: String) = Text(
    text, Modifier.clip(RoundedCornerShape(9.dp)).background(LocalShelfColors.current.surfaceHigh).padding(horizontal = 11.dp, vertical = 6.dp),
    fontSize = 17.sp,
)

/** iOS text field: filled rounded rectangle without the Material outline or underline. */
@Composable
fun IosTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    textStyle: androidx.compose.ui.text.TextStyle = androidx.compose.material3.LocalTextStyle.current,
    label: (@Composable () -> Unit)? = null,
    placeholder: (@Composable () -> Unit)? = null,
    leadingIcon: (@Composable () -> Unit)? = null,
    trailingIcon: (@Composable () -> Unit)? = null,
    keyboardOptions: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
    keyboardActions: androidx.compose.foundation.text.KeyboardActions = androidx.compose.foundation.text.KeyboardActions.Default,
    singleLine: Boolean = false,
    maxLines: Int = if (singleLine) 1 else Int.MAX_VALUE,
    minLines: Int = 1,
) {
    val c = LocalShelfColors.current
    val fill = if (c.dark) Color(0xFF2A2A2E) else Color(0xFFE9E9EE)
    androidx.compose.material3.TextField(
        value = value, onValueChange = onValueChange, modifier = modifier, enabled = enabled, textStyle = textStyle,
        label = label, placeholder = placeholder, leadingIcon = leadingIcon, trailingIcon = trailingIcon,
        keyboardOptions = keyboardOptions, keyboardActions = keyboardActions, singleLine = singleLine, maxLines = maxLines, minLines = minLines,
        shape = RoundedCornerShape(16.dp),
        colors = androidx.compose.material3.TextFieldDefaults.colors(
            focusedContainerColor = fill, unfocusedContainerColor = fill, disabledContainerColor = fill.copy(alpha = 0.6f),
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, disabledIndicatorColor = Color.Transparent,
            focusedLabelColor = Accent, unfocusedLabelColor = c.secondaryText, cursorColor = Accent,
            focusedPlaceholderColor = c.secondaryText, unfocusedPlaceholderColor = c.secondaryText,
        ),
    )
}

/** iOS tinted (bordered) button: a light blue capsule with blue text. */
@Composable
fun IosTintedButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) =
    androidx.compose.material3.FilledTonalButton(
        onClick, modifier, enabled, shape = CircleShape,
        colors = androidx.compose.material3.ButtonDefaults.filledTonalButtonColors(containerColor = Accent.copy(alpha = 0.16f), contentColor = Accent),
        content = content,
    )
