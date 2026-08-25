// DayPageTokens.kt — DayPage v9.0.0 design tokens.
// DO NOT EDIT by hand. Edit design-tokens/tokens.json and run `make tokens-build`.
// Content semantics are shared; components still map these values to native Compose primitives.

package app.daypage.designsystem

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object DayPageTokens {
    const val version = "9.0.0"

    object LightColors {
        val bgWarm = Color(0xFFFAF8F6)
        val surfaceWhite = Color(0xFFFFFFFF)
        val surfaceSunken = Color(0xFFF3F0EB)
        val fgPrimary = Color(0xFF2B2822)
        val fgMuted = Color(0xFF6B6560)
        val fgSubtle = Color(0xFFA39F99)
        val fgSubtleAa = Color(0xFF7A7269)
        val accent = Color(0xFF5D3000)
        val accentHover = Color(0xFF7A3F00)
        val accentSoft = Color(0xFFF5EDE3)
        val accentBorder = Color(0xFFE8DCCA)
        val borderSubtle = Color(0xFFEDE8DF)
        val borderDefault = Color(0xFFD6CEC0)
        val success = Color(0xFF4C7A3F)
        val successSoft = Color(0xFFEBF3E5)
        val warning = Color(0xFFA66A00)
        val warningSoft = Color(0xFFF8ECD6)
        val error = Color(0xFFA23A2E)
        val errorSoft = Color(0xFFF5E1DC)
        val heatmapEmpty = Color(0xFFF0EBE3)
        val heatmapLow = Color(0xFFE6D9C3)
        val heatmapMid = Color(0xFFC9A677)
        val heatmapHigh = Color(0xFF5D3000)
        val recordingRed = Color(0xFFE36B4A)
        val recordingBg = Color(0xFF2D1E0C)
    }

    object DarkColors {
        val bgWarm = Color(0xFF1A1814)
        val surfaceWhite = Color(0xFF1F1C18)
        val surfaceSunken = Color(0xFF252118)
        val fgPrimary = Color(0xFFF0EDE8)
        val fgMuted = Color(0xFFA39F99)
        val fgSubtle = Color(0xFF6B6560)
        val fgSubtleAa = Color(0xFFB8B3AC)
        val accent = Color(0xFFC9883A)
        val accentHover = Color(0xFFE09A45)
        val accentSoft = Color(0xFF2A1F0E)
        val accentBorder = Color(0xFF3D2E14)
        val borderSubtle = Color(0xFF2A2620)
        val borderDefault = Color(0xFF38332A)
        val success = Color(0xFF6AAF5A)
        val successSoft = Color(0xFF1B2E18)
        val warning = Color(0xFFD4940A)
        val warningSoft = Color(0xFF2E2210)
        val error = Color(0xFFD4524A)
        val errorSoft = Color(0xFF2E1210)
        val heatmapEmpty = Color(0xFF252118)
        val heatmapLow = Color(0xFF3D2E14)
        val heatmapMid = Color(0xFF724C1E)
        val heatmapHigh = Color(0xFFE0A04C)
        val recordingRed = Color(0xFFE36B4A)
        val recordingBg = Color(0xFF2D1E0C)
    }

    object Fonts {
        const val display = "Space Grotesk"
        const val serif = "Fraunces"
        const val body = "Inter"
        const val mono = "JetBrains Mono"
    }

    object FontSize {
        val hero = 56.sp
        val titleXl = 34.sp
        val titleLg = 30.sp
        val titleMd = 22.sp
        val titleSm = 21.sp
        val subhead = 19.sp
        val bodyLg = 16.5f.sp
        val body = 16.sp
        val bodySm = 14.5f.sp
        val bodyXs = 13.5f.sp
        val monoMd = 13.sp
        val monoSm = 11.5f.sp
        val monoXs = 11.sp
        val mono2xs = 10.sp
        val mono3xs = 9.sp
    }

    object Radii {
        val small = 8.dp
        val card = 14.dp
        val hero = 18.dp
        val week = 22.dp
        val sheet = 28.dp
        val recording = 34.dp
        val island = 24.dp
        val pill = 999.dp
    }

    object Spacing {
        val cardInner = 20.dp
        val cardGap = 16.dp
        val sectionGap = 24.dp
        val maWeekFeed = 40.dp
    }

    object Motion {
        val spring = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1.0f)
        val easeOut = CubicBezierEasing(0.0f, 0.0f, 0.58f, 1.0f)
        const val fastMillis = 220
        const val mediumMillis = 280
        const val slowMillis = 320
        const val islandMillis = 360
    }

    object ElevationReference {
        const val flat = "0 1px 2px rgba(60,40,15,0.04)"
        const val raise = "0 2px 6px rgba(60,40,15,0.08), 0 12px 24px -12px rgba(60,40,15,0.14)"
        const val float = "0 2px 6px rgba(60,40,15,0.10), 0 24px 48px -16px rgba(60,40,15,0.28)"
        const val flatDark = "0 1px 2px rgba(0,0,0,0.24)"
        const val raiseDark = "0 2px 6px rgba(0,0,0,0.32), 0 12px 24px -12px rgba(0,0,0,0.42)"
        const val floatDark = "0 2px 6px rgba(0,0,0,0.36), 0 24px 48px -16px rgba(0,0,0,0.55)"
    }
}
