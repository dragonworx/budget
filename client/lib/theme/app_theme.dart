import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Deep teal + warm paper Material 3 theme for a finance app.
class AppTheme {
  AppTheme._();

  static const Color _teal = Color(0xFF0B5F5A);
  static const Color _tealDark = Color(0xFF073E3B);
  static const Color _mint = Color(0xFF2BB5A0);
  static const Color _paper = Color(0xFFF3F0E8);
  static const Color _ink = Color(0xFF1A2422);
  static const Color _muted = Color(0xFF5C6B68);
  static const Color _debit = Color(0xFFB54A3C);
  static const Color _credit = Color(0xFF1F7A4D);

  static Color get debitColor => _debit;
  static Color get creditColor => _credit;
  static Color get mint => _mint;

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _teal,
      brightness: Brightness.light,
      primary: _teal,
      onPrimary: Colors.white,
      secondary: _mint,
      onSecondary: _ink,
      surface: _paper,
      onSurface: _ink,
      error: _debit,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: _paper,
    );

    final display = GoogleFonts.frauncesTextTheme(base.textTheme);
    final body = GoogleFonts.sourceSans3TextTheme(base.textTheme);

    final textTheme = body.copyWith(
      displayLarge: display.displayLarge?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      displayMedium: display.displayMedium?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      displaySmall: display.displaySmall?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      headlineLarge: display.headlineLarge?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: display.headlineMedium?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: display.headlineSmall?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: body.titleLarge?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: body.titleMedium?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: body.bodyLarge?.copyWith(color: _ink),
      bodyMedium: body.bodyMedium?.copyWith(color: _ink),
      bodySmall: body.bodySmall?.copyWith(color: _muted),
      labelLarge: body.labelLarge?.copyWith(
        color: _ink,
        fontWeight: FontWeight.w600,
      ),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: _paper,
        foregroundColor: _ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _teal,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _tealDark,
          side: const BorderSide(color: Color(0xFFB7C4C1)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.72),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFCDD6D3)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _teal, width: 1.5),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFFD9E0DD)),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _tealDark,
        contentTextStyle: body.bodyMedium?.copyWith(color: Colors.white),
      ),
    );
  }
}
