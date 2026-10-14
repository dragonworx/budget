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
