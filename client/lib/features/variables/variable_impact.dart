// What a variable change does (spec 012): labels for the fields that use a
// variable, their values, and the "Update $rent?" impact confirm.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/formula/formula_style.dart';
import '../../widgets/money_text.dart';

/// One field (or variable) that references a variable: a row of the usages
/// / attention lists, or of a preview's `changes`.
class VariableUsage {
  const VariableUsage({
    required this.entity,
    required this.entityId,
    required this.field,
    this.streamId,
    this.streamName,
    this.eventName,
    this.variableName,
    this.date,
    this.expr,
    this.value,
    this.oldValue,
    this.newValue,
    this.error,
  });

  factory VariableUsage.fromJson(Map<String, dynamic> j) => VariableUsage(
    entity: '${j['entity'] ?? ''}',
    entityId: '${j['entityId'] ?? ''}',
    field: '${j['field'] ?? ''}',
    streamId: j['streamId'] as String?,
    streamName: j['streamName'] as String?,
    eventName: j['eventName'] as String?,
    variableName: j['variableName'] as String?,
    date: j['date'] as String?,
    expr: j['expr'] as String?,
    value: _str(j['value']),
    oldValue: _str(j['oldValue']),
    newValue: _str(j['newValue']),
    error: _message(j['error']),
  );

  /// `event`, `override`, `stream` or `variable`.
  final String entity;

  /// The event's id (also for an override), the stream's or the variable's.
  final String entityId;
  final String field;
  final String? streamId, streamName, eventName, variableName;

  /// An override's day, `yyyy-mm-dd`.
  final String? date;
  final String? expr, value, oldValue, newValue;

  /// Why the formula no longer works (attention rows).
  final String? error;

  bool get isEvent => entity == 'event' || entity == 'override';

  /// Matches the same field across a preview and the usages list.
  String get slot => '$entity|$entityId|${date ?? ''}|$field';

  static String? _str(Object? v) => v == null ? null : '$v';

  static String? _message(Object? e) => switch (e) {
    null => null,
    Map m => '${m['message'] ?? m['code'] ?? ''}',
    _ => '$e',
  };
}

List<VariableUsage> usagesFromJson(Object? raw) => [
  for (final j in (raw as List?) ?? const [])
    VariableUsage.fromJson(Map<String, dynamic>.from(j as Map)),
];

/// The server's field keys (server/lib/domain/formulas.dart `FormulaField`).
abstract final class VariableFieldKey {
  static const amount = 'amount';
  static const interval = 'interval';
  static const count = 'count';
  static const loanTerm = 'loan.term';
  static const loanChargeDay = 'loan.chargeDay';
  static const loanRatePrefix = 'loan.ratePeriods.';
  static const seedBalance = 'seedBalance';
  static const lossThreshold = 'lossThreshold';
  static const value = 'value';
}

final _day = DateFormat('d MMM y');

String _date(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso);
  return d == null ? (iso ?? '') : _day.format(d);
}

/// A field key's name within its event ("" for the amount itself).
String fieldLabel(String field) => switch (field) {
  VariableFieldKey.amount => '',
  VariableFieldKey.interval => 'Repeat every',
  VariableFieldKey.count => 'Occurrences',
  VariableFieldKey.loanTerm => 'Loan: term',
  VariableFieldKey.loanChargeDay => 'Loan: charge day',
  VariableFieldKey.seedBalance => 'Stream starting balance',
  VariableFieldKey.lossThreshold => 'Loss threshold',
  VariableFieldKey.value => 'Value',
  _ when field.startsWith(VariableFieldKey.loanRatePrefix) =>
    'Loan: interest rate',
  _ => field,
};

/// What a usages row says: "Rent payment", "Rent payment · Loan: interest
/// rate", "Rent payment · Override 12 Mar 2027", "Stream starting balance",
/// "Variable $total".
String usageLabel(VariableUsage u) {
  switch (u.entity) {
    case 'variable':
      return 'Variable \$${u.variableName ?? ''}';
    case 'stream':
      return fieldLabel(u.field);
    case 'override':
      final e = u.eventName ?? 'Event';
      return '$e · Override ${_date(u.date)}';
    default:
      final e = u.eventName ?? 'Event';
      final f = fieldLabel(u.field);
      return f.isEmpty ? e : '$e · $f';
  }
}

/// [raw] formatted for [u]'s field: money for amounts and balances, a
/// percent for rates, a whole number for counts, a variable by its unit
/// ([variableUnits] by lower-case name).
String usageValue(
  VariableUsage u,
  String? raw, {
  Map<String, String> variableUnits = const {},
}) {
  if (raw == null || raw.isEmpty) return '';
  final d = Decimal.tryParse(raw);
  if (d == null) return raw;
  final unit = switch (u.field) {
    VariableFieldKey.amount ||
    VariableFieldKey.seedBalance ||
    VariableFieldKey.lossThreshold => 'money',
    VariableFieldKey.value =>
      variableUnits[(u.variableName ?? '').toLowerCase()] ?? 'number',
    _ when u.field.startsWith(VariableFieldKey.loanRatePrefix) => 'percent',
    _ => 'number',
  };
  return switch (unit) {
    'money' => formatMoneyAmount(d.toDouble(), decimalDigits: 2),
    'percent' => '$raw%',
    _ => formatVariableValue(VariableValue('', d, VariableUnit.number)),
  };
}

/// The impact confirm's body (spec 012): "Changes 14 fields in 3
/// streams", up to five "Rent payment (Home): $1,200.00 → $1,250.00"
/// lines, "+9 more", and the warning when fields would stop working.
/// [names] gives event / stream names by [VariableUsage.slot] (a preview
/// row carries ids only).
String impactMessage(
  List<VariableUsage> changes,
  int invalid, {
  Map<String, VariableUsage> names = const {},
  Map<String, String> variableUnits = const {},
}) {
  final n = changes.length;
  final streams = {
    for (final c in changes)
      if ((c.streamId ?? names[c.slot]?.streamId) != null)
        c.streamId ?? names[c.slot]!.streamId,
  }.length;
  final lines = <String>[
    'Changes ${_count(n, 'field')}'
        '${streams == 0 ? '' : ' in ${_count(streams, 'stream')}'}',
  ];
  for (final c in changes.take(5)) {
    final named = names[c.slot];
    final u = named == null
        ? c
        : VariableUsage(
            entity: c.entity,
            entityId: c.entityId,
            field: c.field,
            streamId: c.streamId ?? named.streamId,
            streamName: named.streamName,
            eventName: named.eventName,
            variableName: named.variableName,
            date: c.date ?? named.date,
          );
    final where = u.streamName == null ? '' : ' (${u.streamName})';
    final from = usageValue(u, c.oldValue, variableUnits: variableUnits);
    final to = c.error != null
        ? 'stops working'
        : usageValue(u, c.newValue, variableUnits: variableUnits);
    lines.add('${usageLabel(u)}$where: $from → $to');
  }
  if (n > 5) lines.add('+${n - 5} more');
  if (invalid > 0) {
    lines.add(
      '${_count(invalid, 'field')} would stop working (they keep their '
      'last value until fixed)',
    );
  }
  return lines.join('\n');
}

String _count(int n, String noun) => '$n ${n == 1 ? noun : '${noun}s'}';

/// "Update $rent?" with [impactMessage]; true = Update.
Future<bool> confirmVariableImpact(
  BuildContext context, {
  required Variable variable,
  required Map<String, dynamic> preview,
  List<VariableUsage> usages = const [],
  Map<String, String> variableUnits = const {},
}) {
  final changes = usagesFromJson(preview['changes']);
  final invalid =
      (preview['invalid'] as num?)?.toInt() ??
      changes.where((c) => c.error != null).length;
  return showConfirmDialog(
    context,
    title: 'Update \$${variable.name}?',
    message: impactMessage(
      changes,
      invalid,
      names: {for (final u in usages) u.slot: u},
      variableUnits: variableUnits,
    ),
    confirmLabel: 'Update',
    isDestructive: false,
  );
}
