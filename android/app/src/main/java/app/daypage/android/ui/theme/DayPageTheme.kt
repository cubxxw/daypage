package app.daypage.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import app.daypage.designsystem.DayPageTokens

private val LightColors = lightColorScheme(
    primary = DayPageTokens.LightColors.accent,
    onPrimary = DayPageTokens.LightColors.surfaceWhite,
    primaryContainer = DayPageTokens.LightColors.accentSoft,
    onPrimaryContainer = DayPageTokens.LightColors.fgPrimary,
    background = DayPageTokens.LightColors.bgWarm,
    onBackground = DayPageTokens.LightColors.fgPrimary,
    surface = DayPageTokens.LightColors.surfaceWhite,
    onSurface = DayPageTokens.LightColors.fgPrimary,
    surfaceVariant = DayPageTokens.LightColors.surfaceSunken,
    onSurfaceVariant = DayPageTokens.LightColors.fgMuted,
    outline = DayPageTokens.LightColors.borderDefault,
    outlineVariant = DayPageTokens.LightColors.borderSubtle,
    error = DayPageTokens.LightColors.error,
    errorContainer = DayPageTokens.LightColors.errorSoft,
)

private val DarkColors = darkColorScheme(
    primary = DayPageTokens.DarkColors.accent,
    onPrimary = Color.Black,
    primaryContainer = DayPageTokens.DarkColors.accentSoft,
    onPrimaryContainer = DayPageTokens.DarkColors.fgPrimary,
    background = DayPageTokens.DarkColors.bgWarm,
    onBackground = DayPageTokens.DarkColors.fgPrimary,
    surface = DayPageTokens.DarkColors.surfaceWhite,
    onSurface = DayPageTokens.DarkColors.fgPrimary,
    surfaceVariant = DayPageTokens.DarkColors.surfaceSunken,
    onSurfaceVariant = DayPageTokens.DarkColors.fgMuted,
    outline = DayPageTokens.DarkColors.borderDefault,
    outlineVariant = DayPageTokens.DarkColors.borderSubtle,
    error = DayPageTokens.DarkColors.error,
    errorContainer = DayPageTokens.DarkColors.errorSoft,
)

private val DayPageTypography = Typography(
    displaySmall = TextStyle(
        fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Medium,
        fontSize = DayPageTokens.FontSize.titleXl,
        lineHeight = DayPageTokens.FontSize.titleXl * 1.12f,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.Serif,
        fontWeight = FontWeight.Medium,
        fontSize = DayPageTokens.FontSize.titleMd,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = DayPageTokens.FontSize.titleSm,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontSize = DayPageTokens.FontSize.bodyLg,
        lineHeight = DayPageTokens.FontSize.bodyLg * 1.5f,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontSize = DayPageTokens.FontSize.bodySm,
        lineHeight = DayPageTokens.FontSize.bodySm * 1.45f,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = DayPageTokens.FontSize.bodySm,
    ),
)

@Composable
fun DayPageTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = DayPageTypography,
        shapes = Shapes(),
        content = content,
    )
}
