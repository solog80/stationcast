import 'package:flutter/material.dart';

/// Dark "control room" palette: near-black surfaces, tally red, meter greens.
abstract final class ControlRoomColors {
  static const background = Color(0xFF0E0F12);
  static const surface = Color(0xFF16181D);
  static const surfaceRaised = Color(0xFF1E2128);
  static const outline = Color(0xFF2E323B);
  static const tallyRed = Color(0xFFFF2B2B);
  static const amber = Color(0xFFFFB020);
  static const meterGreen = Color(0xFF2ECC71);
  static const textPrimary = Color(0xFFF2F3F5);
  static const textSecondary = Color(0xFF9AA0AC);
}

ThemeData buildControlRoomTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: ControlRoomColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: ControlRoomColors.tallyRed,
      secondary: ControlRoomColors.amber,
      surface: ControlRoomColors.surface,
      outline: ControlRoomColors.outline,
      error: ControlRoomColors.tallyRed,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ControlRoomColors.background,
      foregroundColor: ControlRoomColors.textPrimary,
      elevation: 0,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ControlRoomColors.surfaceRaised,
      contentTextStyle: TextStyle(color: ControlRoomColors.textPrimary),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: ControlRoomColors.textPrimary,
      displayColor: ControlRoomColors.textPrimary,
    ),
  );
}

/// Monospace style for stats readouts so numbers don't jitter.
const statsTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontFeatures: [FontFeature.tabularFigures()],
  fontSize: 12,
  color: ControlRoomColors.textPrimary,
);
