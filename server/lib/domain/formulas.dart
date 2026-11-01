// Server-side formula helpers (spec 010): the input guard every text
// passes before a parser sees it, field resolution with the 400 error
// shape, and the field names used by variable_refs.field and the
// expr_errors maps.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';

/// Largest exponent a plain number may carry. Some legacy parsers (loan
/// principal, goal numbers) accept `1e5`; `1e999999999` would build a huge
/// number before any range check, so it is refused first.
const maxPlainExponent = 30;

final _exponentNumber = RegExp(r'^\s*[+-]?[0-9.,\s]*[eE]\s*([+-]?[0-9]+)\s*$');

/// The guard run on every text before [resolveField] (and so before any
/// exponent-accepting legacy parser): length and exponent caps. Null when
/// the text may be parsed.
FormulaError? guardFormulaText(String text) {
  if (text.length > maxFormulaLength) {
    return FormulaError(FormulaErrorCode.tooLong,
        'At most $maxFormulaLength characters', 0, text.length);
  }
  final m = _exponentNumber.firstMatch(text);
  if (m != null) {
    final digits = m[1]!.replaceFirst(RegExp('^[+-]'), '');
    final exp = digits.length > 6 ? null : int.parse(digits);
    if (exp == null || exp > maxPlainExponent) {
      return FormulaError(
          FormulaErrorCode.badNumber, 'Number is too large', 0, text.length);
    }
  }
  return null;
}

/// A formula field the client sent that does not resolve: a 400 with
/// `{"error": message, "details": {code, field, start, end, hint?}}`.
class FormulaFieldException implements Exception {
  FormulaFieldException(this.field, this.error);

  /// The request key, e.g. `amountExpr`, `loan.ratePeriods[0].ratePctExpr`.
  final String field;
  final FormulaError error;

  Map<String, Object?> get details => {
        'code': error.codeName,
        'field': field,
        'start': error.start,
        'end': error.end,
        if (error.hint != null) 'hint': error.hint,
      };

  @override
  String toString() => 'FormulaFieldException($field: ${error.message})';
}

/// A resolved request text: [value] to store and [expr], the canonical
/// formula text (null for a plain number, D14).
class ResolvedText {
  const ResolvedText(this.value, this.expr, this.text);
  final Decimal value;
  final String? expr;

  /// The text as sent (trimmed), for keys that keep plain parts.
  final String text;
  int get intValue => value.toBigInt().toInt();
}

/// Resolves a request's `<field>Expr` value against [vars]. Throws
/// [FormatException] for a non-string and [FormulaFieldException] when it
/// does not resolve (unknown names included).
ResolvedText resolveRequestText(
    Object? raw, FieldSpec spec, VariableLookup vars, String field) {
  if (raw is! String) throw FormatException('$field must be a string');
  final guard = guardFormulaText(raw);
  if (guard != null) throw FormulaFieldException(field, guard);
  final r = resolveField(raw, spec, vars);
  if (!r.ok) throw FormulaFieldException(field, r.error!);
  if (r.value == null) {
    throw FormulaFieldException(
        field, FormulaError(FormulaErrorCode.empty, 'Enter a value', 0, 0));
  }
  return ResolvedText(
      r.value!, r.isFormula ? r.canonicalText : null, raw.trim());
}

/// Resolves a stored text (re-resolution): the value, or the problem to
/// keep in expr_errors (see [errorJson]).
({Decimal? value, FormulaError? error}) resolveStoredText(
    String text, FieldSpec spec, VariableLookup vars) {
  final guard = guardFormulaText(text);
  if (guard != null) return (value: null, error: guard);
  final r = resolveField(text, spec, vars);
  if (r.error != null) return (value: null, error: r.error);
  if (r.value == null) {
    return (
      value: null,
      error: FormulaError(FormulaErrorCode.empty, 'Enter a value', 0, 0),
    );
  }
  return (value: r.value, error: null);
}

/// The stored form of a field problem: `{code, message}`.
Map<String, Object?> errorJson(FormulaError e) =>
    {'code': e.codeName, 'message': e.message};

/// The interval spec for a frequency rule (2 minimum for "Every N").
FieldSpec intervalSpecForRule(String? rule) =>
    intervalSpec(rule == 'every_n_weeks' || rule == 'every_n_months' ? 2 : 1);

/// Field names (variable_refs.field, expr_errors keys).
abstract final class FormulaField {
  static const amount = 'amount';
  static const interval = 'interval';
  static const count = 'count';
  static const loanTerm = 'loan.term';
  static const loanChargeDay = 'loan.chargeDay';
  static String loanRate(int i) => 'loan.ratePeriods.$i.ratePct';
  static const seedBalance = 'seedBalance';
  static const lossThreshold = 'lossThreshold';
  static const value = 'value';

  /// Every loan field key a loan's expr_errors may hold.
  static List<String> loanKeys(int periods) => [
        loanTerm,
        loanChargeDay,
        for (var i = 0; i < periods; i++) loanRate(i),
      ];
}

/// A loan rate as stored: at most 4 decimals, no trailing zeros.
String loanRateText(Decimal v) => v.toString();

/// The formula texts of an event row by field ([FormulaField]): its expr
/// columns and the loan JSON's expr keys. The term field carries both of
/// its texts joined, for name extraction only.
Map<String, String> eventFieldTexts({
  String? amountExpr,
  String? intervalExpr,
  String? countExpr,
  Map<String, dynamic>? loan,
}) {
  final out = <String, String>{
    if (amountExpr != null) FormulaField.amount: amountExpr,
    if (intervalExpr != null) FormulaField.interval: intervalExpr,
    if (countExpr != null) FormulaField.count: countExpr,
  };
  if (loan != null) {
    final y = loan['termYearsExpr'], m = loan['termMonthsExpr'];
    if (y is String || m is String) {
      out[FormulaField.loanTerm] = '${y ?? ''} ${m ?? ''}';
    }
    final c = loan['chargeDayExpr'];
    if (c is String) out[FormulaField.loanChargeDay] = c;
    final periods = loan['ratePeriods'];
    if (periods is List) {
      for (var i = 0; i < periods.length; i++) {
        final p = periods[i];
        if (p is Map && p['ratePctExpr'] is String) {
          out[FormulaField.loanRate(i)] = p['ratePctExpr'] as String;
        }
      }
    }
  }
  return out;
}

/// Lower-case names [text] references (empty for unparseable text).
Set<String> namesIn(String text) {
  if (guardFormulaText(text) != null) return const {};
  try {
    return referencedNames(text).map((n) => n.toLowerCase()).toSet();
  } on Object {
    return const {};
  }
}
