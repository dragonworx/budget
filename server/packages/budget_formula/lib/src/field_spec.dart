import 'package:decimal/decimal.dart';

/// How a field's resolved value is constrained and shown.
enum FieldUnit { money, percent, integer, number }

/// Messages a field shows; plain inputs use today's strings.
enum FieldMessage {
  /// Nothing typed (and the field needs a value).
  empty,

  /// Typed text that is neither a plain number nor a formula (plain-number
  /// rejection copy; formulas report their own error).
  invalid,

  /// Exactly zero where the minimum is exclusive zero.
  zero,

  /// Below zero where negatives aren't allowed.
  negative,
  belowMin,
  aboveMax,
}

/// One formula-capable field. Server (010) and client (011/013) use these,
/// never their own ranges.
class FieldSpec {
  final String id;
  final FieldUnit unit;

  /// Formula results are rounded to this many decimals (half away from
  /// zero); integer fields (0) reject non-whole results instead.
  final int scale;
  final Decimal? min;
  final bool minExclusive;
  final Decimal? max;

  /// Whether negative values are allowed at all.
  final bool signed;

  /// Formula results only: largest magnitude (plain numbers keep today's
  /// rules).
  final Decimal? formulaMax;

  /// Whether [min]/[max] apply to plain numbers too (true where today's
  /// field validates them; goal fields leave range checks to the server).
  final bool checkPlainRange;

  /// Whether empty text is fine; its value is then [emptyValue].
  final bool allowEmpty;
  final Decimal? emptyValue;

  /// D14: today's parser for the field.
  final Decimal? Function(String) legacyParse;
  final Map<FieldMessage, String> messages;

  const FieldSpec({
    required this.id,
    required this.unit,
    required this.scale,
    required this.legacyParse,
    this.min,
    this.minExclusive = false,
    this.max,
    this.signed = false,
    this.formulaMax,
    this.checkPlainRange = true,
    this.allowEmpty = false,
    this.emptyValue,
    this.messages = const {},
  });

  bool get isInteger => unit == FieldUnit.integer;

  FieldSpec copyWith({
    Decimal? min,
    Decimal? max,
    Map<FieldMessage, String>? messages,
  }) =>
      FieldSpec(
        id: id,
        unit: unit,
        scale: scale,
        legacyParse: legacyParse,
        min: min ?? this.min,
        minExclusive: minExclusive,
        max: max ?? this.max,
        signed: signed,
        formulaMax: formulaMax,
        checkPlainRange: checkPlainRange,
        allowEmpty: allowEmpty,
        emptyValue: emptyValue,
        messages: messages ?? this.messages,
      );

  /// [v] for messages: grouped thousands, `$` for money, `%` for percent.
  String format(Decimal v) {
    final neg = v < Decimal.zero;
    final s = v.abs().toString();
    final dot = s.indexOf('.');
    final ip = dot < 0 ? s : s.substring(0, dot);
    final fp = dot < 0 ? '' : s.substring(dot);
    final g = StringBuffer();
    for (var i = 0; i < ip.length; i++) {
      if (i > 0 && (ip.length - i) % 3 == 0) g.write(',');
      g.write(ip[i]);
    }
    final body = '$g$fp';
    return switch (unit) {
      FieldUnit.money => '${neg ? '-' : ''}\$$body',
      FieldUnit.percent => '${neg ? '-' : ''}$body%',
      _ => '${neg ? '-' : ''}$body',
    };
  }

  /// Why [v] is out of this field's range (null when fine). [formula]
  /// adds the formula-only cap.
  String? rangeProblem(Decimal v, {required bool formula}) {
    if (!signed && v < Decimal.zero) {
      return messages[FieldMessage.negative] ??
          messages[FieldMessage.belowMin] ??
          (min != null ? _below() : 'Must not be negative');
    }
    final lo = min;
    if (lo != null && (v < lo || (minExclusive && v == lo))) {
      if (v == Decimal.zero && messages[FieldMessage.zero] != null) {
        return messages[FieldMessage.zero];
      }
      return messages[FieldMessage.belowMin] ?? _below();
    }
    final hi = max;
    if (hi != null && v > hi) {
      return messages[FieldMessage.aboveMax] ?? 'At most ${format(hi)}';
    }
    final cap = formulaMax;
    if (formula && cap != null && v.abs() > cap) {
      return 'At most ${format(cap)}';
    }
    return null;
  }

  String _below() => minExclusive
      ? 'Must be above ${format(min!)}'
      : 'At least ${format(min!)}';
}
