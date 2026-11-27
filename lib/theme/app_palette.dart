import 'package:flutter/material.dart';

/// The complete fixed color palette for All in One.
///
/// These are the ONLY hex colors allowed anywhere in the app. Every other
/// color (tints, states, shadows, scrims) must be derived from these via
/// opacity (`withValues(alpha: ...)`).
abstract final class AppHex {
  AppHex._();

  // ── Light mode palette ────────────────────────────────────────────────
  static const Color lightPrimary = Color(0xFF075E55); // Primary
  static const Color lightSecondary = Color(0xFF128C7F); // Secondary
  static const Color lightAccent = Color(0xFF26D367); // Accent
  static const Color lightBackground = Color(0xFFF7F5F1); // Main Background
  static const Color lightCard = Color(0xFFFFFFFF); // Card / Surface
  static const Color lightTextPrimary = Color(0xFF173B36); // Primary Text
  static const Color lightTextSecondary = Color(0xFF71817B); // Secondary Text
  static const Color lightBorder = Color(0xFFDCD8D1); // Border
  static const Color critical = Color(0xFF8E1E2D);

  // ── Dark mode palette ─────────────────────────────────────────────────
  static const Color darkPrimary = Color(0xFF26D367); // Primary
  static const Color darkSecondary = Color(0xFF128C7F); // Secondary
  static const Color darkAccent = Color(0xFFECE5DD); // Accent
  static const Color darkBackground = Color(0xFF101B19); // Main Background
  static const Color darkCard = Color(0xFF1B2926); // Card Background
  static const Color darkElevated = Color(0xFF243632); // Elevated Surface
  static const Color darkTextPrimary = Color(0xFFF5F2EC); // Primary Text
  static const Color darkTextSecondary = Color(0xFFAABBB3); // Secondary Text
  static const Color darkBorder = Color(0xFF38514B); // Border
}

/// Semantic color roles for one brightness mode.
///
/// Resolve it with `context.palette` (never hardcode hex values).
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.isDark,
    required this.background,
    required this.card,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.onPrimary,
    required this.onSecondary,
    required this.onAccent,
    required this.border,
    required this.shadow,
    required this.scrim,
    required this.onScrim,
    required this.videoScrim,
    required this.onVideoScrim,
    required this.videoAccent,
  });

  final bool isDark;

  /// Page / scaffold background.
  final Color background;

  /// Cards, tiles, inputs — the standard container.
  final Color card;

  /// Elevated surfaces: dialogs, bottom sheets, snackbars, popups.
  final Color surface;

  /// Titles, body, values.
  final Color textPrimary;

  /// Meta text, hints, disabled labels, muted icons.
  final Color textSecondary;

  /// Brand fill: primary buttons, selected nav, progress, focus.
  final Color primary;

  /// Outline / info states: outline buttons, links, info status.
  final Color secondary;

  /// Positive emphasis: success, active dots, highlights.
  final Color accent;

  /// Content drawn on top of [primary] fills.
  final Color onPrimary;

  /// Content drawn on top of [secondary] fills.
  final Color onSecondary;

  /// Content drawn on top of [accent] fills.
  final Color onAccent;

  /// Dividers, outlines, disabled surfaces.
  final Color border;

  /// Base color for shadows — always used with an alpha (see [shadowAt]).
  final Color shadow;

  /// Base color for scrims/overlays — always used with an alpha (see [scrimAt]).
  final Color scrim;

  /// Content drawn on top of [scrim] overlays.
  final Color onScrim;

  /// Neutral dark overlay used by the video player HUD. It is intentionally
  /// dark in both modes so controls stay legible over arbitrary video frames,
  /// while its content/accent colors still follow the active app theme.
  final Color videoScrim;

  /// Icons and labels drawn on top of [videoScrim].
  final Color onVideoScrim;

  /// Player progress dot, seek bar and active controls. Always the brand
  /// green so it remains visible on the dark video scrim in light mode.
  final Color videoAccent;

  // ── Semantic aliases ──────────────────────────────────────────────────

  /// General errors use the existing neutral UI role.
  Color get error => textSecondary;

  /// Destructive actions use a dark red on light surfaces and a readable tint
  /// on dark surfaces.
  Color get critical => isDark
      ? Color.lerp(AppHex.critical, textPrimary, .6)!
      : AppHex.critical;

  /// Success/active green — `#26D367` in both modes.
  Color get success => isDark ? primary : accent;

  /// Informational state.
  Color get info => secondary;

  // ── Derived state colors (palette + opacity only) ─────────────────────

  /// Any palette color at a given opacity.
  Color tint(Color base, double alpha) => base.withValues(alpha: alpha);

  /// Hover / subtle highlight background.
  Color get hoverBg => tint(primary, isDark ? 0.08 : 0.06);

  /// Pressed background.
  Color get pressedBg => tint(primary, isDark ? 0.18 : 0.14);

  /// Selected/active pill, chip, nav background.
  Color get selectedBg => tint(primary, isDark ? 0.24 : 0.10);

  /// Progress/slider inactive track background.
  Color get trackBg => tint(primary, isDark ? 0.12 : 0.10);

  /// Disabled container background.
  Color get disabledBg => tint(border, isDark ? 0.55 : 0.60);

  /// Disabled content color.
  Color get disabledText => textSecondary;

  /// Shadow at the given opacity.
  Color shadowAt(double alpha) => shadow.withValues(alpha: alpha);

  /// Scrim/overlay at the given opacity.
  Color scrimAt(double alpha) => scrim.withValues(alpha: alpha);

  /// Video HUD overlay at the given opacity.
  Color videoScrimAt(double alpha) => videoScrim.withValues(alpha: alpha);

  /// Brand call-to-action gradient — the only gradient shape allowed.
  LinearGradient get primaryGradient => LinearGradient(
        colors: [primary, secondary],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static const AppPalette light = AppPalette(
    isDark: false,
    background: AppHex.lightBackground,
    card: AppHex.lightCard,
    surface: AppHex.lightCard,
    textPrimary: AppHex.lightTextPrimary,
    textSecondary: AppHex.lightTextSecondary,
    primary: AppHex.lightPrimary,
    secondary: AppHex.lightSecondary,
    accent: AppHex.lightAccent,
    onPrimary: AppHex.lightCard, // #FFFFFF
    onSecondary: AppHex.lightCard, // #FFFFFF
    onAccent: AppHex.lightTextPrimary, // #173B36
    border: AppHex.lightBorder,
    shadow: AppHex.lightPrimary,
    scrim: AppHex.lightPrimary,
    onScrim: AppHex.lightCard, // #FFFFFF
    videoScrim: AppHex.lightTextPrimary,
    onVideoScrim: AppHex.lightCard,
    videoAccent: AppHex.lightAccent,
  );

  static const AppPalette dark = AppPalette(
    isDark: true,
    background: AppHex.darkBackground,
    card: AppHex.darkCard,
    surface: AppHex.darkElevated,
    textPrimary: AppHex.darkTextPrimary,
    textSecondary: AppHex.darkTextSecondary,
    primary: AppHex.darkPrimary,
    secondary: AppHex.darkSecondary,
    accent: AppHex.darkAccent,
    onPrimary: AppHex.darkBackground, // #101B19
    onSecondary: AppHex.darkAccent, // #ECE5DD
    onAccent: AppHex.darkBackground, // #101B19
    border: AppHex.darkBorder,
    shadow: AppHex.darkBackground,
    scrim: AppHex.darkBackground,
    onScrim: AppHex.darkTextPrimary, // #F5F2EC
    videoScrim: AppHex.darkBackground,
    onVideoScrim: AppHex.darkTextPrimary,
    videoAccent: AppHex.darkPrimary,
  );

  /// Never throws: falls back to the palette matching the theme brightness,
  /// so plain `MaterialApp`s (tests) also resolve correctly.
  static AppPalette of(BuildContext context) {
    final extension =
        Theme.of(context).extension<AppPalette>() ??
        (Theme.of(context).brightness == Brightness.dark ? dark : light);
    _current = extension;
    return extension;
  }

  static AppPalette _current = light;

  /// Last palette resolved through [of]. Lets color-only helpers that have no
  /// `BuildContext` read the same mode-aware palette instead of duplicating
  /// brightness checks.
  static AppPalette get current => _current;

  /// Called by the theme builder whenever the app palette is (re)created.
  static void sync(AppPalette palette) => _current = palette;

  @override
  AppPalette copyWith({
    bool? isDark,
    Color? background,
    Color? card,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
    Color? primary,
    Color? secondary,
    Color? accent,
    Color? onPrimary,
    Color? onSecondary,
    Color? onAccent,
    Color? border,
    Color? shadow,
    Color? scrim,
    Color? onScrim,
    Color? videoScrim,
    Color? onVideoScrim,
    Color? videoAccent,
  }) {
    return AppPalette(
      isDark: isDark ?? this.isDark,
      background: background ?? this.background,
      card: card ?? this.card,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      primary: primary ?? this.primary,
      secondary: secondary ?? this.secondary,
      accent: accent ?? this.accent,
      onPrimary: onPrimary ?? this.onPrimary,
      onSecondary: onSecondary ?? this.onSecondary,
      onAccent: onAccent ?? this.onAccent,
      border: border ?? this.border,
      shadow: shadow ?? this.shadow,
      scrim: scrim ?? this.scrim,
      onScrim: onScrim ?? this.onScrim,
      videoScrim: videoScrim ?? this.videoScrim,
      onVideoScrim: onVideoScrim ?? this.onVideoScrim,
      videoAccent: videoAccent ?? this.videoAccent,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      isDark: t < 0.5 ? isDark : other.isDark,
      background: Color.lerp(background, other.background, t)!,
      card: Color.lerp(card, other.card, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      onSecondary: Color.lerp(onSecondary, other.onSecondary, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      border: Color.lerp(border, other.border, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      videoScrim: Color.lerp(videoScrim, other.videoScrim, t)!,
      onVideoScrim: Color.lerp(onVideoScrim, other.onVideoScrim, t)!,
      videoAccent: Color.lerp(videoAccent, other.videoAccent, t)!,
    );
  }
}

/// `context.palette` — the canonical way to read colors.
extension AppPaletteContext on BuildContext {
  AppPalette get palette => AppPalette.of(this);
}
