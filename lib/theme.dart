import 'package:flutter/material.dart';

/// Farben im Spotify-Stil – Akzent dunkelblau statt grün.
class AppColors {
  static const accent = Color(0xFF1E50E0); // gefüllte Buttons
  static const accentLight = Color(0xFF5B8CFF); // Text/Icons auf dunklem Grund
  static const headerTop = Color(0xFF2347A8);
  static const headerMid = Color(0xFF14295F);
  static const topBar = Color(0xFF13285E);
  static const miniPlayer = Color(0xFF1C2B4F);

  static const background = Color(0xFF121212);
  static const surface = Color(0xFF181818);
  static const elevated = Color(0xFF282828);
  static const navBar = Color(0xFF0A0A0A);

  static const textSecondary = Color(0xFFB3B3B3);
  static const textMuted = Color(0xFF727272);
}

ThemeData buildTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      secondary: AppColors.accentLight,
      surface: AppColors.background,
      onPrimary: Colors.white,
      onSurface: Colors.white,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
      iconTheme: IconThemeData(color: Colors.white),
    ),
    iconTheme: const IconThemeData(color: Colors.white),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.elevated,
      modalBackgroundColor: AppColors.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Colors.white,
      contentTextStyle: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
      behavior: SnackBarBehavior.floating,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accentLight),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accentLight,
      selectionHandleColor: AppColors.accentLight,
    ),
    dividerColor: Colors.white12,
  );
}
