import 'package:flutter/material.dart';

class AppColors {
  // Brand reds
  static const Color primary = Color(0xFFA51D32);
  static const Color primaryDark = Color(0xFF7C1023);
  static const Color primaryLight = Color(0xFFE05265);
  static const Color primaryDeep = Color(0xFF551021);
  static const Color primarySurface = Color(0xFF2C131A);

  // Accents
  static const Color accentGold = Color(0xFFFFC107); // Electric Gold
  static const Color accentRed = Color(
    0xFFE50914,
  ); // Dark Crimson Red (Netflix/YouTube Red)
  static const Color accentGreen = Color(0xFF10B981); // Mint Green
  static const Color accentBlue = Color(0xFF3B82F6); // Cyber Blue
  static const Color accentPurple = Color(0xFF8B5CF6); // Deep Violet

  // Dark surfaces
  static const Color darkBg = Color(0xFF181114);
  static const Color darkSurface = Color(0xFF21171B);
  static const Color darkCard = Color(0xFF2C1F24);
  static const Color darkBorder = Color(0xFF493238);
  static const Color darkTextPrimary = Color(0xFFF9FAFB);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextTertiary = Color(0xFF64748B);

  // Light Theme Surfaces
  static const Color lightBg = Color(0xFFFCF6F7);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightBorder = Color(0xFFEFDFE3);
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF475569);
  static const Color lightTextTertiary = Color(0xFF94A3B8);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFFA51D32), Color(0xFF711022)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient crimsonGradient = LinearGradient(
    colors: [Color(0xFFE50914), Color(0xFFB91C1C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient proBadgeGradient = LinearGradient(
    colors: [Color(0xFFE05265), Color(0xFFA51D32)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient cardDarkGradient = LinearGradient(
    colors: [Color(0xFF182330), Color(0xFF121B24)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
