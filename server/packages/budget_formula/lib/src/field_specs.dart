import 'package:decimal/decimal.dart';

import 'field_spec.dart';
import 'legacy.dart';

Decimal _d(String s) => Decimal.parse(s);
Decimal? _int(String s) {
  final n = parseLegacyInt(s);
  return n == null ? null : Decimal.fromInt(n);
}

/// A variable's plain value: a decimal with optional `,`/`_` separators
/// (no exponent: a new field, so nothing to stay compatible with, and
/// `1e999999999` must not reach `Decimal`).
Decimal? parseVariableValuePlain(String input) {
  final t = input.trim().replaceAll(RegExp('[,_]'), '');
  if (!RegExp(r'^[+-]?(\d+(\.\d+)?|\.\d+)$').hasMatch(t)) return null;
  return Decimal.parse(t.startsWith('+') ? t.substring(1) : t);
}

final Decimal _moneyCap = _d('999999999999.99');

/// `event.interval`'s spec for a rule whose minimum is [min] (1, or 2 for
/// "Every N" rules): today's message is "min–99".
FieldSpec intervalSpec(int min, {String id = 'event.interval'}) {
  final m = '$min–99';
  return FieldSpec(
    id: id,
    unit: FieldUnit.integer,
    scale: 0,
    legacyParse: _int,
    min: Decimal.fromInt(min),
    max: Decimal.fromInt(99),
    messages: {
      FieldMessage.empty: m,
      FieldMessage.invalid: m,
      FieldMessage.belowMin: m,
      FieldMessage.aboveMax: m,
    },
  );
}

FieldSpec _money(String id,
        {required Decimal? Function(String) legacy,
        required Map<FieldMessage, String> messages,
        bool signed = false,
        bool allowEmpty = false,
        Decimal? emptyValue,
        bool checkPlainRange = true}) =>
    FieldSpec(
      id: id,
      unit: FieldUnit.money,
      scale: 2,
      legacyParse: legacy,
      min: signed ? null : Decimal.zero,
      minExclusive: !signed,
      signed: signed,
      formulaMax: _moneyCap,
      checkPlainRange: checkPlainRange,
      allowEmpty: allowEmpty,
      emptyValue: emptyValue,
      messages: messages,
    );

FieldSpec _integer(String id,
        {required int min,
        int? max,
        Decimal? formulaMax,
        bool allowEmpty = false,
        required String message,
        String? empty}) =>
    FieldSpec(
      id: id,
      unit: FieldUnit.integer,
      scale: 0,
      legacyParse: _int,
      min: Decimal.fromInt(min),
      max: max == null ? null : Decimal.fromInt(max),
      formulaMax: formulaMax,
      allowEmpty: allowEmpty,
      messages: {
        FieldMessage.empty: empty ?? message,
        FieldMessage.invalid: message,
        FieldMessage.negative: message,
        FieldMessage.belowMin: message,
        FieldMessage.aboveMax: message,
      },
    );

const _goalInvalid = {FieldMessage.invalid: 'Invalid number'};

/// Every formula-capable field, by id. Plain-number messages are today's
/// strings (sources cited per entry, HEAD e429c1b).
final Map<String, FieldSpec> fieldSpecs = {
  for (final s in <FieldSpec>[
    // event_editor.dart L982-L993 (also transfer, once-off, split and the
    // loan "Set up repayments" amount).
    _money('event.amount', legacy: parseLegacyMoney, messages: const {
      FieldMessage.empty: 'Enter an amount',
      FieldMessage.invalid: 'Enter a number, e.g. 1250 or 1,250.50',
      FieldMessage.zero: 'Enter an amount above zero',
      FieldMessage.negative: 'Use Money out instead of a negative amount',
    }),
    // loan_form.dart L311-L316.
    _money('loan.principal', legacy: parseLegacyPrincipal, messages: const {
      FieldMessage.empty: 'Enter the amount borrowed',
      FieldMessage.invalid: 'Enter a number, e.g. 500000',
      FieldMessage.zero: 'Enter an amount above zero',
      FieldMessage.negative: 'Enter an amount above zero',
    }),
    // widgets/stream_dialog.dart L288-L293.
    _money('stream.seed',
        legacy: parseLegacyMoney,
        signed: true,
        messages: const {
          FieldMessage.empty: 'Enter an amount, e.g. 2500 or -120.50',
          FieldMessage.invalid: 'Enter an amount, e.g. 2500 or -120.50',
        }),
    _money('stream.threshold',
        legacy: parseLegacyMoney,
        signed: true,
        allowEmpty: true,
        emptyValue: Decimal.zero,
        messages: const {
          FieldMessage.invalid:
              'Enter an amount, e.g. 200 (or leave empty for 0)',
        }),
    // rate_periods_editor.dart L54 rateTextError.
    FieldSpec(
      id: 'loan.ratePct',
      unit: FieldUnit.percent,
      scale: 4,
      legacyParse: parseLegacyRate,
      min: Decimal.zero,
      max: Decimal.fromInt(100),
      messages: const {
        FieldMessage.empty: 'Enter a rate',
        FieldMessage.invalid: 'A number like 6.4 (up to 4 decimals)',
        FieldMessage.negative: 'At least 0%',
        FieldMessage.aboveMax: 'At most 100%',
      },
    ),
    // loan_form.dart _intField L651 (3 digits; the combined 1–600 months
    // is checked by the form).
    _integer('loan.termYears',
        min: 0, max: 999, message: 'A term of 1 month to 50 years'),
    _integer('loan.termMonths',
        min: 0, max: 999, message: 'A term of 1 month to 50 years'),
    // loan_form.dart L592.
    _integer('loan.chargeDay', min: 1, max: 31, message: 'A day from 1 to 31'),
    // frequency_picker.dart L146 (min 2 for "Every N" rules: intervalSpec).
    intervalSpec(1),
    // event_editor.dart L1336.
    _integer('event.count',
        min: 1, formulaMax: Decimal.fromInt(100000), message: 'At least 1'),
    // solve_sheet.dart L159-L166.
    for (final id in ['solve.total', 'solve.amount'])
      _money(id,
          legacy: parseLegacyDecimalRaw,
          allowEmpty: true,
          messages: const {
            FieldMessage.invalid: 'Invalid amount',
            FieldMessage.zero: 'Must be > 0',
            FieldMessage.negative: 'Must be > 0',
          }),
    // solve_sheet.dart L279 (RecurrenceIntervalField, blank allowed) and
    // L168 _intError.
    _integer('solve.interval',
        min: 1, max: 99, allowEmpty: true, message: '1–99'),
    _integer('solve.count',
        min: 1, allowEmpty: true, message: 'Whole number ≥ 1'),
    // goal_panel.dart L226-L237 ("Invalid number"; ranges are the
    // server's, goal_solver.dart L255).
    for (final id in [
      'goal.startBalance',
      'goal.targetBalance',
      'goal.amount',
      'goal.oneOff',
    ])
      _money(id,
          legacy: parseLegacyDoubleRaw,
          signed: true,
          allowEmpty: true,
          checkPlainRange: false,
          messages: _goalInvalid),
    FieldSpec(
      id: 'goal.rate',
      unit: FieldUnit.percent,
      scale: 4,
      legacyParse: parseLegacyDoubleRaw,
      min: Decimal.zero,
      max: Decimal.fromInt(1000),
      checkPlainRange: false,
      allowEmpty: true,
      messages: const {
        FieldMessage.invalid: 'Invalid number',
        FieldMessage.negative: 'Between 0 and 1000%',
        FieldMessage.aboveMax: 'Between 0 and 1000%',
      },
    ),
    _integer('goal.count', min: 0, allowEmpty: true, message: 'Whole number'),
    // goal_panel.dart L639 RecurrenceIntervalField.
    _integer('goal.interval', min: 1, max: 99, message: '1–99'),
    // A variable's own value (any unit), up to 10 decimals (D4).
    FieldSpec(
      id: 'variable.value',
      unit: FieldUnit.number,
      scale: 10,
      legacyParse: parseVariableValuePlain,
      signed: true,
      messages: const {
        FieldMessage.empty: 'Enter a value',
        FieldMessage.invalid: 'Enter a number or a formula',
      },
    ),
  ])
    s.id: s,
};
