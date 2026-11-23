import 'package:flutter/material.dart';

import 'app_palette.dart';

/// Transitional compatibility token.
///
/// All UI code reads colors through `context.palette` (see `app_palette.dart`).
/// This single token remains because tests assert the light primary brand
/// color through it; it must always resolve to the fixed palette value.
class AppColors {
  AppColors._();

  /// Light-mode primary brand color: `#075E55`.
  static const Color primary = AppHex.lightPrimary;
}
