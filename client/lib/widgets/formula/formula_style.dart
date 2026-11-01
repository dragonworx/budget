// Theme tokens and value formatting for formula fields (spec 011).
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../money_text.dart';

/// How each highlighted span kind is drawn on top of the field's [base]
/// style. Colour, background, weight (≤ w600) and decoration only: never
/// size, spacing or glyphs, so caret positions match an unstyled field.
abstract final class FormulaStyle {
  static const Color operator = AppTheme.textMuted;
  static const Color known = AppTheme.accent;
  static const Color knownBackground = AppTheme.accentSoft;
  static const Color unknown = AppTheme.warning;
  static Color get error => AppTheme.debitColor;

  static TextStyle? span(SpanStyle s, TextStyle? base) {
    final b = base ?? const TextStyle();
    return switch (s) {
      SpanStyle.number || SpanStyle.whitespace => null,
      SpanStyle.operator ||
      SpanStyle.paren ||
      SpanStyle.currency => b.copyWith(color: operator),
      SpanStyle.variableKnown => b.copyWith(
        color: known,
        backgroundColor: knownBackground,
        fontWeight: FontWeight.w600,
      ),
      SpanStyle.variableUnknown => b.copyWith(
        color: unknown,
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: unknown,
      ),
      SpanStyle.invalid || SpanStyle.reserved => b.copyWith(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: error,
      ),
    };
  }
}

/// A field's resolved value for the preview line: money via
/// [formatMoneyAmount] at the field's scale, percent `5.75%`, integer `13`.
String formatFieldValue(Decimal v, FieldSpec spec) => switch (spec.unit) {
  FieldUnit.money => formatMoneyAmount(v.toDouble(), decimalDigits: spec.scale),
  FieldUnit.percent => '${_plain(v)}%',
  FieldUnit.integer || FieldUnit.number => _grouped(v),
};

/// A variable's current value as the suggestion list shows it:
/// `$1,200.00`, `5.5%`, `52`; [decimals] is its display precision.
String formatVariableValue(VariableValue v, {int? decimals}) {
  return switch (v.unit) {
    VariableUnit.money => formatMoneyAmount(
      v.value.toDouble(),
      decimalDigits: decimals ?? 2,
    ),
    VariableUnit.percent =>
      '${decimals == null ? _plain(v.value) : _fixed(v.value, decimals)}%',
    VariableUnit.number =>
      decimals == null ? _grouped(v.value) : _fixed(v.value, decimals),
  };
}

/// For screen readers: "1,200 dollars", "5.5 percent", "52".
String spokenVariableValue(VariableValue v) {
  final n = _grouped(v.value);
  return switch (v.unit) {
    VariableUnit.money => '$n dollars',
    VariableUnit.percent => '$n percent',
    VariableUnit.number => n,
  };
}

String unitBadge(VariableUnit u) => switch (u) {
  VariableUnit.money => r'$',
  VariableUnit.percent => '%',
  VariableUnit.number => '#',
};

String _plain(Decimal v) => v.toString();

String _grouped(Decimal v) {
  final s = v.toString();
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final dot = body.indexOf('.');
  final ip = dot < 0 ? body : body.substring(0, dot);
  final fp = dot < 0 ? '' : body.substring(dot);
  final g = NumberFormat.decimalPattern('en_AU').format(int.parse(ip));
  return '${neg ? '-' : ''}$g$fp';
}

String _fixed(Decimal v, int decimals) => NumberFormat.decimalPatternDigits(
  locale: 'en_AU',
  decimalDigits: decimals,
).format(v.toDouble());

/// [text] with its tokens styled like a formula field draws them
/// (read-only lists: usages, attention, the manager's formula line).
TextSpan styledFormula(
  String text,
  TextStyle? base,
  bool Function(String lowerName) isKnown,
) => TextSpan(
  style: base,
  children: [
    for (final sp in highlight(text, isKnown))
      TextSpan(
        text: text.substring(sp.start, sp.end),
        style: FormulaStyle.span(sp.style, base),
      ),
  ],
);
