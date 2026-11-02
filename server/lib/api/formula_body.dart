// Resolution on write (spec 010 rule 2): a request's `<field>Expr` keys
// are resolved before the existing parsers run. The resolved number
// replaces the body's plain value, so the legacy write path stores it
// unchanged; the canonical text goes to the expr columns.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';

import '../domain/enums.dart';
import '../domain/formulas.dart';
import '../domain/models.dart';
import '../domain/variable_service.dart';
import '../repo/event_repo.dart';
import '../repo/stream_repo.dart';
import '../repo/variable_repo.dart';

const _loanTextKeys = ['termYearsExpr', 'termMonthsExpr', 'chargeDayExpr'];

/// Whether [body] carries formula text the server must resolve (so it
/// needs the owner's variables).
bool bodyHasFormulas(Map<String, dynamic> body) {
  bool s(Object? v) => v is String;
  if (s(body['amountExpr']) ||
      s(body['occurrenceCountExpr']) ||
      s(body['seedBalanceExpr']) ||
      s(body['lossThresholdExpr'])) {
    return true;
  }
  final f = body['frequency'];
  if (f is Map && s(f['intervalExpr'])) return true;
  final l = body['loan'];
  if (l is Map) {
    if (_loanTextKeys.any((k) => s(l[k]))) return true;
    final p = l['ratePeriods'];
    if (p is List && p.any((x) => x is Map && s(x['ratePctExpr']))) {
      return true;
    }
  }
  return false;
}

/// Whether [json] mentions formulas at all: any `*Expr` key or a
/// scenario's `exprs` (feature flag off → 400 `formulas_disabled`).
bool mentionsFormulas(Object? json) {
  if (json is Map) {
    for (final e in json.entries) {
      final k = e.key.toString();
      if (k.endsWith('Expr') || k == 'exprs') return true;
      if (mentionsFormulas(e.value)) return true;
    }
  } else if (json is List) {
    return json.any(mentionsFormulas);
  }
  return false;
}

class EventFormulaPrep {
  const EventFormulaPrep(this.exprs, {this.resolvedDifferently = false});
  final EventExprWrite exprs;
  final bool resolvedDifferently;
}

bool _differs(Object? sent, Decimal value) {
  if (sent == null) return false;
  final d = Decimal.tryParse(sent.toString().trim());
  return d == null || d != value;
}

/// Resolves an event create/patch [body]'s formula keys in place against
/// [vars] (the resolving owner's variables) and returns the expr columns
/// to write. A plain value sent without its expr key clears the expr.
/// Throws [FormulaFieldException] or [FormatException].
EventFormulaPrep prepareEventBody(
    Map<String, dynamic> body, VariableLookup vars,
    {required EventKind kind}) {
  final columns = <String, String?>{};
  final clear = <String>[];
  var differs = false;

  // amount
  if (body.containsKey('amountExpr')) {
    final raw = body.remove('amountExpr');
    if (raw != null) {
      final r =
          resolveRequestText(raw, amountSpecFor(kind), vars, 'amountExpr');
      differs |= _differs(body['amount'], r.value);
      body['amount'] = r.value.toString();
      columns['amount_expr'] = r.expr;
    } else {
      columns['amount_expr'] = null;
    }
    clear.add(FormulaField.amount);
  } else if (body['amount'] != null) {
    columns['amount_expr'] = null;
    clear.add(FormulaField.amount);
  }

  // interval (inside the structured frequency)
  final freq = body['frequency'];
  if (freq is Map && freq.containsKey('intervalExpr')) {
    final f = Map<String, dynamic>.from(freq);
    body['frequency'] = f;
    final raw = f.remove('intervalExpr');
    if (raw != null) {
      final rule = f['rule']?.toString();
      if (rule == 'once') {
        throw const FormatException('A one-off has no interval');
      }
      final r = resolveRequestText(
          raw, intervalSpecForRule(rule), vars, 'frequency.intervalExpr');
      differs |= _differs(f['interval'], r.value);
      f['interval'] = r.intValue;
      columns['interval_expr'] = r.expr;
    } else {
      columns['interval_expr'] = null;
    }
    clear.add(FormulaField.interval);
  } else if (freq != null ||
      body['interval'] != null ||
      body['recurrenceMode'] != null) {
    columns['interval_expr'] = null;
    clear.add(FormulaField.interval);
  }

  // occurrence count
  if (body.containsKey('occurrenceCountExpr')) {
    final raw = body.remove('occurrenceCountExpr');
    if (raw != null) {
      final r = resolveRequestText(
          raw, fieldSpecs['event.count']!, vars, 'occurrenceCountExpr');
      differs |= _differs(body['occurrenceCount'], r.value);
      body['occurrenceCount'] = r.intValue;
      columns['count_expr'] = r.expr;
    } else {
      columns['count_expr'] = null;
    }
    clear.add(FormulaField.count);
  } else if (body.containsKey('occurrenceCount') ||
      (body['endMode'] != null && body['endMode'] != 'count')) {
    columns['count_expr'] = null;
    clear.add(FormulaField.count);
  }

  // loan terms (whole-terms replace: every loan field error goes)
  final loan = body['loan'];
  if (loan is Map) {
    final l = Map<String, dynamic>.from(loan);
    body['loan'] = l;
    differs |= _prepareLoan(l, vars);
    final periods = l['ratePeriods'];
    clear.addAll(FormulaField.loanKeys(periods is List ? periods.length : 0));
  }
  return EventFormulaPrep(EventExprWrite(columns, clear),
      resolvedDifferently: differs);
}

/// Resolves the loan JSON's expr keys in place: numbers into their plain
/// keys; formula texts kept canonical, plain texts dropped (D14).
bool _prepareLoan(Map<String, dynamic> l, VariableLookup vars) {
  var differs = false;
  for (final k in _loanTextKeys) {
    if (l.containsKey(k) && l[k] == null) l.remove(k);
  }
  final y = l['termYearsExpr'], m = l['termMonthsExpr'];
  if (y != null || m != null) {
    final ry = y == null
        ? null
        : resolveRequestText(
            y, fieldSpecs['loan.termYears']!, vars, 'loan.termYearsExpr');
    final rm = m == null
        ? null
        : resolveRequestText(
            m, fieldSpecs['loan.termMonths']!, vars, 'loan.termMonthsExpr');
    final total = (ry?.intValue ?? 0) * 12 + (rm?.intValue ?? 0);
    if (total < 1 || total > 600) {
      final field = y != null ? 'loan.termYearsExpr' : 'loan.termMonthsExpr';
      final len = ((y ?? m) as String).length;
      throw FormulaFieldException(
          field,
          FormulaError(FormulaErrorCode.outOfRange,
              'A loan term is 1 month to 50 years', 0, len));
    }
    differs |= _differs(l['termMonths'], Decimal.fromInt(total));
    l['termMonths'] = total;
    final anyFormula = ry?.expr != null || rm?.expr != null;
    if (!anyFormula) {
      l.remove('termYearsExpr');
      l.remove('termMonthsExpr');
    } else {
      if (ry != null) l['termYearsExpr'] = ry.expr ?? ry.text;
      if (rm != null) l['termMonthsExpr'] = rm.expr ?? rm.text;
    }
  }
  final c = l['chargeDayExpr'];
  if (c != null) {
    final r = resolveRequestText(
        c, fieldSpecs['loan.chargeDay']!, vars, 'loan.chargeDayExpr');
    differs |= _differs(l['chargeDay'], r.value);
    l['chargeDay'] = r.intValue;
    if (r.expr == null) {
      l.remove('chargeDayExpr');
    } else {
      l['chargeDayExpr'] = r.expr;
    }
  }
  final periods = l['ratePeriods'];
  if (periods is List) {
    final out = <Object?>[];
    for (var i = 0; i < periods.length; i++) {
      final p = periods[i];
      if (p is Map && p.containsKey('ratePctExpr')) {
        final pm = Map<String, dynamic>.from(p);
        final raw = pm.remove('ratePctExpr');
        if (raw != null) {
          final r = resolveRequestText(raw, fieldSpecs['loan.ratePct']!, vars,
              'loan.ratePeriods[$i].ratePctExpr');
          differs |= _differs(pm['ratePct'], r.value);
          pm['ratePct'] = loanRateText(r.value);
          if (r.expr != null) pm['ratePctExpr'] = r.expr;
        }
        out.add(pm);
      } else {
        out.add(p);
      }
    }
    l['ratePeriods'] = out;
  }
  return differs;
}

class StreamFormulaPrep {
  const StreamFormulaPrep(this.exprs, {this.resolvedDifferently = false});
  final StreamExprWrite exprs;
  final bool resolvedDifferently;
}

/// [prepareEventBody] for a stream create/patch: `seedBalanceExpr` →
/// `seedBalance`, `lossThresholdExpr` → `lossThreshold`.
StreamFormulaPrep prepareStreamBody(
    Map<String, dynamic> body, VariableLookup vars) {
  final columns = <String, String?>{};
  final clear = <String>[];
  var differs = false;
  for (final (key, column, spec, field) in [
    (
      'seedBalance',
      'seed_balance_expr',
      'stream.seed',
      FormulaField.seedBalance
    ),
    (
      'lossThreshold',
      'loss_threshold_expr',
      'stream.threshold',
      FormulaField.lossThreshold
    ),
  ]) {
    final exprKey = '${key}Expr';
    if (body.containsKey(exprKey)) {
      final raw = body.remove(exprKey);
      if (raw != null) {
        final r = resolveRequestText(raw, fieldSpecs[spec]!, vars, exprKey);
        differs |= _differs(body[key], r.value);
        body[key] = r.value.toString();
        columns[column] = r.expr;
      } else {
        columns[column] = null;
      }
      clear.add(field);
    } else if (body.containsKey(key)) {
      columns[column] = null;
      clear.add(field);
    }
  }
  return StreamFormulaPrep(StreamExprWrite(columns, clear),
      resolvedDifferently: differs);
}

/// Scenario `request.exprs` (D11): validated, not evaluated. Keys are the
/// goal fields; values formula texts (or null to drop).
const scenarioExprKeys = {
  'startBalance',
  'targetBalance',
  'amount',
  'oneOff',
  'rate',
  'count',
  'interval',
};

/// Checks a scenario request's `exprs` map; throws [FormulaFieldException]
/// or [FormatException]. Returns it cleaned (nulls dropped), or null.
Map<String, String>? validateScenarioExprs(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) throw const FormatException('exprs must be an object');
  final out = <String, String>{};
  for (final e in raw.entries) {
    final k = e.key.toString();
    if (!scenarioExprKeys.contains(k)) {
      throw FormatException('exprs.$k is not a formula field');
    }
    final v = e.value;
    if (v == null) continue;
    if (v is! String) throw FormatException('exprs.$k must be a string');
    final guard = guardFormulaText(v);
    if (guard != null) throw FormulaFieldException('exprs.$k', guard);
    final p = parseFormula(v);
    if (!p.ok) throw FormulaFieldException('exprs.$k', p.error!);
    out[k] = v.trim();
  }
  return out;
}

/// [json] plus `formulaResolvedDifferently: true` when a formula's value
/// differed from the plain number the client also sent (rule 2). Plain
/// requests get [json] unchanged.
Map<String, dynamic> withResolvedFlag(Map<String, dynamic> json, bool flag) =>
    flag ? {...json, 'formulaResolvedDifferently': true} : json;

/// [prepareEventBody] with the resolving owner's variables, loaded only
/// when the body carries formula text.
Future<EventFormulaPrep> prepareEventFormulas(
    Session db, Map<String, dynamic> body,
    {required String streamId,
    BudgetEvent? existing,
    required EventKind kind}) async {
  VariableLookup vars = const MapVariableLookup.empty();
  if (bodyHasFormulas(body)) {
    final direction =
        body['direction']?.toString() ?? existing?.direction.name ?? 'debit';
    final peerStream = body.containsKey('transferToStreamId')
        ? body['transferToStreamId']?.toString()
        : existing?.transfer?.peerStreamId;
    // D10: a transfer's credit side resolves against the debit side's
    // owner (falling back to its own stream's).
    vars = await VariableRepo(db).lookupForStream(streamId,
        preferStreamId: direction == 'credit' ? peerStream : null);
  }
  return prepareEventBody(body, vars, kind: kind);
}

/// An override body's `amountExpr` (resolved like the event's amount).
Future<({String? expr, bool resolvedDifferently})> prepareOverrideFormula(
    Session db, String eventId, Map<String, dynamic> body) async {
  final raw = body.remove('amountExpr');
  if (raw == null) return (expr: null, resolvedDifferently: false);
  final owner = await VariableService(db).resolvingOwnerOf(eventId);
  final vars = owner == null
      ? const MapVariableLookup.empty()
      : await VariableRepo(db).lookup(owner);
  final r =
      resolveRequestText(raw, fieldSpecs['event.amount']!, vars, 'amountExpr');
  final differs = _differs(body['amount'], r.value);
  body['amount'] = r.value.toString();
  return (expr: r.expr, resolvedDifferently: differs);
}

/// [prepareStreamBody] with [ownerId]'s variables when needed.
Future<StreamFormulaPrep> prepareStreamFormulas(
    Session db, Map<String, dynamic> body, String ownerId) async {
  final vars = bodyHasFormulas(body)
      ? await VariableRepo(db).lookup(ownerId)
      : const MapVariableLookup.empty();
  return prepareStreamBody(body, vars);
}
