import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/app_theme.dart';

class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    required this.currency,
    this.style,
    this.colorBySign = false,
  });

  final Decimal amount;
  final String currency;
  final TextStyle? style;
  final bool colorBySign;

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat.currency(
      name: currency,
      symbol: symbolFor(currency),
    );
    final value = amount.toDouble();
    final color = !colorBySign
        ? null
        : value < 0
        ? AppTheme.debitColor
        : value > 0
        ? AppTheme.creditColor
        : null;

    return Text(
      format.format(value),
      style: (style ?? Theme.of(context).textTheme.titleMedium)?.copyWith(
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  static String symbolFor(String currency) {
    switch (currency.toUpperCase()) {
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      case 'AUD':
        return 'A\$';
      case 'CAD':
        return 'C\$';
      case 'JPY':
        return '¥';
      default:
        return '$currency ';
    }
  }
}

/// Axis and chart labels. [decimalDigits] overrides the size-based default.
String formatMoneyAmount(num amount, String currency, {int? decimalDigits}) {
  final digits = decimalDigits ?? (amount.abs() >= 100 ? 0 : 2);
  return NumberFormat.currency(
    name: currency,
    symbol: MoneyText.symbolFor(currency),
    decimalDigits: digits,
  ).format(amount);
}

/// A single transaction's amount, signed by direction: "+A$1,830" for a
/// credit, "−A$22.99" for a debit. Compact ("+A$1.36M") from a million up.
String formatSignedAmount(num signedAmount, String currency) {
  final abs = signedAmount.abs();
  final text = abs >= 1e6
      ? NumberFormat.compactCurrency(
          name: currency,
          symbol: MoneyText.symbolFor(currency),
          decimalDigits: 2,
        ).format(abs)
      : formatMoneyAmount(abs, currency);
  if (abs == 0) return text;
  return '${signedAmount < 0 ? '−' : '+'}$text';
}

/// Parses a typed amount, tolerating thousands separators, spaces and a
/// leading currency symbol ("A$1,250.50", "-1 200"). Null when invalid.
Decimal? parseMoneyInput(String input) {
  var t = input.trim().replaceAll(RegExp(r'[\s,_]'), '');
  var negative = false;
  if (t.startsWith('-')) {
    negative = true;
    t = t.substring(1);
  }
  t = t.replaceFirst(RegExp(r'^[A-Za-z]{0,3}[$€£¥]?'), '');
  if (t.startsWith('-')) {
    negative = !negative;
    t = t.substring(1);
  }
  if (!RegExp(r'^\d+(\.\d+)?$|^\.\d+$').hasMatch(t)) return null;
  final d = Decimal.tryParse(t);
  if (d == null) return null;
  return negative ? -d : d;
}
