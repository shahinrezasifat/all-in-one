import 'package:flutter/material.dart';

import 'app_palette.dart';

/// Single source of theme truth. Both brightness modes are built from the
/// matching [AppPalette]; no color literal lives outside `lib/theme/`.
class AppTheme {
  static const _noStroke = ButtonStyle(
    side: WidgetStatePropertyAll(BorderSide.none),
  );

  static ThemeData get lightTheme => _build(AppPalette.light, Brightness.light);
  static ThemeData get darkTheme => _build(AppPalette.dark, Brightness.dark);

  static ThemeData _build(AppPalette p, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      extensions: <ThemeExtension<dynamic>>[p],
      brightness: brightness,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: p.primary,
        onPrimary: p.onPrimary,
        secondary: p.secondary,
        onSecondary: p.onSecondary,
        tertiary: p.accent,
        onTertiary: p.onAccent,
        error: p.error,
        onError: p.card,
        surface: p.surface,
        onSurface: p.textPrimary,
        surfaceContainerHighest: p.card,
        onSurfaceVariant: p.textSecondary,
        outline: p.border,
        outlineVariant: p.border,
        shadow: p.shadow,
        scrim: p.scrim,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: p.textPrimary),
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.card,
        elevation: p.isDark ? 0 : 1,
        shadowColor: p.shadowAt(0.12),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.bold,
        ),
        contentTextStyle: TextStyle(color: p.textSecondary, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.card,
        hintStyle: TextStyle(color: p.textSecondary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.primary, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            inherit: false,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: p.border),
          backgroundColor: p.tint(p.primary, 0.10),
          foregroundColor: p.primary,
        ),
      ),
      filledButtonTheme: const FilledButtonThemeData(style: _noStroke),
      textButtonTheme: const TextButtonThemeData(style: _noStroke),
      iconButtonTheme: const IconButtonThemeData(style: _noStroke),
      segmentedButtonTheme: const SegmentedButtonThemeData(style: _noStroke),
      chipTheme: ChipThemeData(
        side: BorderSide(color: p.border),
        backgroundColor: p.card,
        selectedColor: p.selectedBg,
        disabledColor: p.disabledBg,
        labelStyle: TextStyle(color: p.textPrimary),
        secondaryLabelStyle: TextStyle(color: p.primary),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: p.primary,
        labelColor: p.primary,
        unselectedLabelColor: p.textSecondary,
        dividerColor: p.border,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.normal,
          fontSize: 14,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        backgroundColor: p.surface,
        contentTextStyle: TextStyle(color: p.textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.trackBg,
        secondaryActiveTrackColor: p.secondary,
        thumbColor: p.primary,
        overlayColor: p.tint(p.primary, 0.12),
        valueIndicatorColor: p.primary,
        valueIndicatorTextStyle: TextStyle(color: p.onPrimary),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled) ? p.disabledText : p.primary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? p.selectedBg : p.trackBg),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.trackBg,
        circularTrackColor: p.trackBg,
        refreshBackgroundColor: p.card,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [BoxShadow(color: p.shadowAt(0.20), blurRadius: 8)],
        ),
        textStyle: TextStyle(color: p.textPrimary, fontSize: 12),
      ),
    );
  }
}
