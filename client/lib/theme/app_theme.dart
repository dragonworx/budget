import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dark, layered Material 3 theme.
///
/// Surfaces step up in lightness (bg → surface → raised → overlay) instead of
/// relying on shadows; 1px borders separate them. Credit/debit colours are
/// tuned for AA contrast on every surface.
class AppTheme {
  AppTheme._();

  // Surfaces, darkest to lightest.
  static const Color bg = Color(0xFF0D1117);
  static const Color surface = Color(0xFF141A22);
  static const Color raised = Color(0xFF1A212B);
  static const Color overlay = Color(0xFF222B37);
  static const Color border = Color(0xFF2A3441);
  static const Color borderStrong = Color(0xFF3A4656);

  // Text.
  static const Color text = Color(0xFFE6EBF2);
  static const Color textMuted = Color(0xFFA2ADBC); // ≥7:1 on surface
  static const Color textFaint = Color(0xFF7F8A9A); // ≥4.5:1 on bg/surface

  // Accent and semantics.
  static const Color accent = Color(0xFF3DD6B5);
  static const Color onAccent = Color(0xFF032119);
  static const Color accentSoft = Color(0xFF173A35);
  static const Color violet = Color(0xFF9AA6FF);
  static const Color _credit = Color(0xFF45D48C);
  static const Color _debit = Color(0xFFFF7B7B);
  static const Color warning = Color(0xFFF2B84B);

  /// Dashed plan-preview line and the planning target marker.
  static const Color planGhost = Color(0xFFFFC857);

  /// Saved what-if scenario lines, in order.
  static const List<Color> scenarioColors = [
    Color(0xFF6FB7FF),
    Color(0xFFE38BFF),
    Color(0xFFFF9F68),
    Color(0xFF8BE0A4),
    Color(0xFFFF6FA5),
  ];

  static Color get debitColor => _debit;
  static Color get creditColor => _credit;
  static Color get mint => accent;

  /// Tinted fill behind credit / debit chips.
  static Color creditSoft = _credit.withValues(alpha: 0.14);
  static Color debitSoft = _debit.withValues(alpha: 0.14);

  /// Transfers between pools (violet: neither income nor spend).
  static const Color transferColor = violet;
  static Color transferSoft = violet.withValues(alpha: 0.14);

  static const double radius = 12;
  static BorderRadius get radiusAll => BorderRadius.circular(radius);

  /// Card-like container: tonal fill plus a hairline border.
  static BoxDecoration panel({Color? color, double r = radius, Color? edge}) =>
      BoxDecoration(
        color: color ?? surface,
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: edge ?? border),
      );

  /// Keyboard focus gets a clear 2px ring; otherwise [normal].
  static WidgetStateProperty<BorderSide?> _focusRing(
    BorderSide? normal,
    Color ring,
  ) => WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.focused)
        ? BorderSide(color: ring, width: 2)
        : normal,
  );

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: accentSoft,
      onPrimaryContainer: Color(0xFFBFF5E8),
      secondary: violet,
      onSecondary: Color(0xFF111633),
      secondaryContainer: Color(0xFF262D57),
      onSecondaryContainer: Color(0xFFDDE1FF),
      tertiary: warning,
      onTertiary: Color(0xFF2A1C00),
      error: _debit,
      onError: Color(0xFF3B0A0A),
      errorContainer: Color(0xFF4A1C1F),
      onErrorContainer: Color(0xFFFFD9D6),
      surface: surface,
      onSurface: text,
      onSurfaceVariant: textMuted,
      surfaceContainerLowest: bg,
      surfaceContainerLow: Color(0xFF11161D),
      surfaceContainer: surface,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: overlay,
      outline: borderStrong,
      outlineVariant: border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: text,
      onInverseSurface: bg,
      inversePrimary: Color(0xFF0B6B58),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: InkSparkle.splashFactory,
    );

    final body = GoogleFonts.interTextTheme(base.textTheme);
    final display = GoogleFonts.manropeTextTheme(base.textTheme);
    TextStyle? head(
      TextStyle? s, {
      double? size,
      FontWeight w = FontWeight.w700,
    }) => s?.copyWith(
      color: text,
      fontWeight: w,
      fontSize: size,
      letterSpacing: -0.2,
    );

    final textTheme = body
        .apply(bodyColor: text, displayColor: text)
        .copyWith(
          displaySmall: head(display.displaySmall),
          headlineMedium: head(display.headlineMedium),
          headlineSmall: head(display.headlineSmall, size: 22),
          titleLarge: head(display.titleLarge, size: 19),
          titleMedium: body.titleMedium?.copyWith(
            color: text,
            fontWeight: FontWeight.w600,
          ),
          titleSmall: body.titleSmall?.copyWith(
            color: text,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: body.bodyLarge?.copyWith(color: text),
          bodyMedium: body.bodyMedium?.copyWith(color: text),
          bodySmall: body.bodySmall?.copyWith(color: textMuted),
          labelLarge: body.labelLarge?.copyWith(
            color: text,
            fontWeight: FontWeight.w600,
          ),
          labelMedium: body.labelMedium?.copyWith(color: textMuted),
          labelSmall: body.labelSmall?.copyWith(color: textMuted),
        );

    final shape = RoundedRectangleBorder(borderRadius: radiusAll);
    const pad = EdgeInsets.symmetric(horizontal: 14, vertical: 12);

    OutlineInputBorder inputBorder(Color c, [double w = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c, width: w),
        );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        shape: const Border(bottom: BorderSide(color: border)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radiusAll,
          side: const BorderSide(color: border),
        ),
      ),
      dividerTheme: const DividerThemeData(color: border, space: 1),
      iconTheme: const IconThemeData(color: textMuted, size: 20),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 2,
        shape: shape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: overlay,
          disabledForegroundColor: textFaint,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ).copyWith(side: _focusRing(null, text)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          backgroundColor: raised,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ).copyWith(side: _focusRing(const BorderSide(color: border), accent)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ).copyWith(side: _focusRing(null, accent)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textMuted,
          highlightColor: overlay,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ).copyWith(side: _focusRing(null, accent)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accentSoft : raised,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accent : textMuted,
          ),
          side: _focusRing(const BorderSide(color: border), accent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: raised,
        selectedColor: accentSoft,
        side: const BorderSide(color: border),
        labelStyle: textTheme.labelMedium?.copyWith(color: text),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: accent),
        checkmarkColor: accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF10151C),
        contentPadding: pad,
        labelStyle: const TextStyle(color: textMuted),
        floatingLabelStyle: const TextStyle(color: accent),
        hintStyle: const TextStyle(color: textFaint),
        helperStyle: const TextStyle(color: textFaint),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        border: inputBorder(border),
        enabledBorder: inputBorder(border),
        focusedBorder: inputBorder(accent, 1.5),
        errorBorder: inputBorder(_debit),
        focusedErrorBorder: inputBorder(_debit, 1.5),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? onAccent : textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : overlay,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : borderStrong,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textMuted,
        textColor: text,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
        titleTextStyle: textTheme.titleLarge,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: surface,
        dragHandleColor: borderStrong,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          side: BorderSide(color: border),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        textStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
      ),
      menuTheme: const MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(raised),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: overlay,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderStrong),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: text),
        waitDuration: const Duration(milliseconds: 400),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: overlay,
        actionTextColor: accent,
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderStrong),
        ),
        width: 520,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: Colors.transparent,
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: raised,
        headerForegroundColor: text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      scrollbarTheme: const ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(borderStrong),
      ),
    );
  }

  /// Kept for callers that still ask for the old name.
  static ThemeData light() => dark();
}
