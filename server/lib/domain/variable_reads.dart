// Read side of variables (spec 010): usages of one variable and the
// owner's rows needing attention, filtered to streams the caller reads.
import 'dart:convert';

import 'package:postgres/postgres.dart';

import 'formulas.dart';

Map<String, dynamic>? _json(Object? v) => v == null
    ? null
    : Map<String, dynamic>.from((v is String ? jsonDecode(v) : v) as Map);

/// A loan field's text and value from the loan JSON.
(String?, Object?) _loanField(Map<String, dynamic>? loan, String field) {
  if (loan == null) return (null, null);
  if (field == FormulaField.loanTerm) {
    final t = [loan['termYearsExpr'], loan['termMonthsExpr']]
        .whereType<String>()
        .join(' · ');
    return (t.isEmpty ? null : t, loan['termMonths']);
  }
  if (field == FormulaField.loanChargeDay) {
    return (loan['chargeDayExpr'] as String?, loan['chargeDay']);
  }
  final parts = field.split('.');
  final periods = loan['ratePeriods'];
  if (parts.length == 4 && periods is List) {
    final i = int.tryParse(parts[2]) ?? -1;
    if (i >= 0 && i < periods.length && periods[i] is Map) {
      final p = periods[i] as Map;
      return (p['ratePctExpr'] as String?, p['ratePct']);
    }
  }
  return (null, null);
}

/// Fields using variable [variableId]. [readable] null: every stream.
Future<Map<String, Object?>> variableUsages(
    Session db, String variableId, Set<String>? readable) async {
  final rows = await db.execute(
    Sql.named('''
      SELECT r.stream_id::text, s.name, r.event_id::text,
             r.override_date::text, r.field, r.from_variable_id::text,
             e.name, e.amount::text, e.freq_interval, e.occurrence_count,
             e.loan, e.amount_expr, e.interval_expr, e.count_expr,
             e.expr_errors, o.amount::text, o.amount_expr, o.expr_error,
             s.seed_balance::text, s.loss_threshold::text,
             s.seed_balance_expr, s.loss_threshold_expr, s.expr_errors,
             fv.name, fv.expr, fv.value::text, fv.problem, e.kind
      FROM variable_refs r
      LEFT JOIN streams s ON s.id = r.stream_id
      LEFT JOIN events e ON e.id = r.event_id
      LEFT JOIN occurrence_overrides o
             ON o.event_id = r.event_id AND o.date = r.override_date
      LEFT JOIN variables fv ON fv.id = r.from_variable_id
      WHERE r.variable_id = @v::uuid
      ORDER BY s.name NULLS FIRST, e.name, r.override_date NULLS FIRST,
               r.field
    '''),
    parameters: {'v': variableId},
  );
  final usages = <Map<String, Object?>>[];
  var hidden = 0;
  for (final r in rows) {
    final stream = r[0] as String?;
    if (stream != null && readable != null && !readable.contains(stream)) {
      hidden++;
      continue;
    }
    final field = r[4] as String;
    if (r[5] != null) {
      usages.add({
        'entity': 'variable',
        'entityId': r[5],
        'variableName': r[23],
        'field': field,
        'expr': r[24],
        'value': r[25],
        if (r[26] != null) 'error': _json(r[26]),
      });
      continue;
    }
    final base = <String, Object?>{
      'streamId': stream,
      'streamName': r[1],
    };
    if (r[2] == null) {
      final seed = field == FormulaField.seedBalance;
      usages.add({
        ...base,
        'entity': 'stream',
        'entityId': stream,
        'field': field,
        'expr': seed ? r[20] : r[21],
        'value': seed ? r[18] : r[19],
        if (_json(r[22])?[field] != null) 'error': _json(r[22])![field],
      });
      continue;
    }
    if (r[3] != null) {
      usages.add({
        ...base,
        'entity': 'override',
        'entityId': r[2],
        'eventName': r[6],
        'date': r[3],
        'field': field,
        'expr': r[16],
        'value': r[15],
        if (r[17] != null) 'error': _json(r[17]),
      });
      continue;
    }
    final (expr, value) = switch (field) {
      FormulaField.amount => (r[11], r[7]),
      FormulaField.interval => (r[12], r[8]),
      FormulaField.count => (r[13], r[9]),
      _ => _loanField(_json(r[10]), field),
    };
    final err = _json(r[14])?[field];
    usages.add({
      ...base,
      'entity': 'event',
      'entityId': r[2],
      'eventName': r[6],
      if (r[27] == 'sync') 'eventKind': 'sync',
      'field': field,
      'expr': expr,
      'value': value is num || value is String ? '$value' : value,
      if (err != null) 'error': err,
    });
  }
  return {'usages': usages, 'hidden': hidden};
}

/// Rows of [ownerId]'s that need attention: fields whose formula no
/// longer resolves and variables with a problem.
Future<Map<String, Object?>> variableAttention(
    Session db, String ownerId, Set<String>? readable) async {
  final items = <Map<String, Object?>>[];
  bool can(String s) => readable == null || readable.contains(s);

  final vars = await db.execute(
    Sql.named('SELECT id::text, name, expr, problem FROM variables '
        'WHERE owner_id = @o::uuid AND problem IS NOT NULL ORDER BY name'),
    parameters: {'o': ownerId},
  );
  for (final r in vars) {
    items.add({
      'entity': 'variable',
      'entityId': r[0],
      'variableName': r[1],
      'field': FormulaField.value,
      'expr': r[2],
      'error': _json(r[3]),
    });
  }
  final events = await db.execute(
    Sql.named('''
      SELECT e.id::text, e.stream_id::text, s.name, e.name, e.expr_errors
      FROM events e JOIN streams s ON s.id = e.stream_id
      WHERE s.owner_id = @o::uuid AND e.expr_errors IS NOT NULL
        AND (e.transfer_id IS NULL OR e.direction = 'debit')
      ORDER BY s.name, e.name
    '''),
    parameters: {'o': ownerId},
  );
  for (final r in events) {
    if (!can(r[1] as String)) continue;
    final errs = _json(r[4]) ?? const {};
    for (final e in errs.entries) {
      items.add({
        'entity': 'event',
        'entityId': r[0],
        'streamId': r[1],
        'streamName': r[2],
        'eventName': r[3],
        'field': e.key,
        'error': e.value,
      });
    }
  }
  final ovs = await db.execute(
    Sql.named('''
      SELECT e.id::text, e.stream_id::text, s.name, e.name, o.date::text,
             o.amount_expr, o.expr_error
      FROM occurrence_overrides o
      JOIN events e ON e.id = o.event_id
      JOIN streams s ON s.id = e.stream_id
      WHERE s.owner_id = @o::uuid AND o.expr_error IS NOT NULL
        AND (e.transfer_id IS NULL OR e.direction = 'debit')
      ORDER BY s.name, e.name, o.date
    '''),
    parameters: {'o': ownerId},
  );
  for (final r in ovs) {
    if (!can(r[1] as String)) continue;
    items.add({
      'entity': 'override',
      'entityId': r[0],
      'streamId': r[1],
      'streamName': r[2],
      'eventName': r[3],
      'date': r[4],
      'field': FormulaField.amount,
      'expr': r[5],
      'error': _json(r[6]),
    });
  }
  final streams = await db.execute(
    Sql.named('SELECT id::text, name, expr_errors FROM streams '
        'WHERE owner_id = @o::uuid AND expr_errors IS NOT NULL ORDER BY name'),
    parameters: {'o': ownerId},
  );
  for (final r in streams) {
    if (!can(r[0] as String)) continue;
    for (final e in (_json(r[2]) ?? const {}).entries) {
      items.add({
        'entity': 'stream',
        'entityId': r[0],
        'streamId': r[0],
        'streamName': r[1],
        'field': e.key,
        'error': e.value,
      });
    }
  }
  return {'items': items, 'count': items.length};
}

/// How many attention rows [ownerId] has (list response's `attention`).
Future<int> attentionCount(
        Session db, String ownerId, Set<String>? readable) async =>
    ((await variableAttention(db, ownerId, readable))['count'] as int);
