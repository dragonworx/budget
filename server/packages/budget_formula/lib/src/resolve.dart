import 'package:decimal/decimal.dart';

import 'ast.dart';
import 'errors.dart';
import 'evaluator.dart';
import 'field_spec.dart';
import 'lexer.dart';
import 'parser.dart';
import 'rewrite.dart';
import 'rounding.dart';
import 'token.dart';

enum FormulaHintCode { percentInAmount, moneyInRate }

/// A non-blocking note about a valid formula (D13).
class FormulaHint {
  final FormulaHintCode code;
  final String message;
  final int start;
  final int end;
  const FormulaHint(this.code, this.message, this.start, this.end);

  String get codeName => code.name
      .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

  @override
  String toString() => 'FormulaHint($codeName [$start,$end) "$message")';
}

/// What a field's text means.
class FieldResolution {
  /// Today's parser accepted it (D14): [value] is exactly what it returned
  /// (no rounding, no formula cap) and [canonicalText] is null.
  final bool isPlain;

  /// Parsed as a formula (whether or not it worked).
  final bool isFormula;

  /// The resolved value (null on error, or for an allowed empty field
  /// without a default).
  final Decimal? value;
  final FormulaError? error;
  final List<FormulaHint> hints;

  /// The text to store in `*_expr` (formulas only, also on error).
  final String? canonicalText;

  /// Lower-case variable names the text uses.
  final Set<String> referencedLower;
  final List<FormulaToken> tokens;

  const FieldResolution({
    required this.isPlain,
    required this.isFormula,
    this.value,
    this.error,
    this.hints = const [],
    this.canonicalText,
    this.referencedLower = const {},
    this.tokens = const [],
  });

  bool get ok => error == null;

  @override
  String toString() =>
      'FieldResolution(${isPlain ? 'plain' : isFormula ? 'formula' : 'empty'}'
      ' value=$value error=$error canonical=$canonicalText)';
}

/// Resolves [text] for [spec] against [vars] (the one call server and
/// client make).
FieldResolution resolveField(String text, FieldSpec spec, VariableLookup vars) {
  final t = text.trim();
  final tokens = tokenize(text);
  if (t.isEmpty) {
    if (spec.allowEmpty) {
      return FieldResolution(
          isPlain: true,
          isFormula: false,
          value: spec.emptyValue,
          tokens: tokens);
    }
    return FieldResolution(
        isPlain: false,
        isFormula: false,
        tokens: tokens,
        error: FormulaError(FormulaErrorCode.empty,
            spec.messages[FieldMessage.empty] ?? 'Enter a value', 0, 0));
  }

  final legacy = spec.legacyParse(text);
  if (legacy != null) {
    FormulaError? err;
    if (spec.unit == FieldUnit.number && legacy.scale > spec.scale) {
      err = FormulaError(FormulaErrorCode.tooManyDecimals,
          'At most ${spec.scale} decimal places', 0, text.length);
    } else if (spec.checkPlainRange) {
      final p = spec.rangeProblem(legacy, formula: false);
      if (p != null) {
        err = FormulaError(FormulaErrorCode.outOfRange, p, 0, text.length);
      }
    }
    return FieldResolution(
        isPlain: true,
        isFormula: false,
        value: err == null ? legacy : null,
        error: err,
        tokens: tokens);
  }

  final refs = referencedNames(text);
  final canonical = canonicalise(text, vars);
  FieldResolution fail(FormulaError e) => FieldResolution(
      isPlain: false,
      isFormula: true,
      error: e,
      canonicalText: canonical,
      referencedLower: refs,
      tokens: tokens);

  final parsed = parseFormula(text);
  FormulaError? err = parsed.error;
  if (spec.unit != FieldUnit.money) {
    // A `$` before a number only means "dollars" in money fields.
    for (final k in tokens) {
      if (k.kind == TokenKind.currencySigil) {
        if (err == null || k.start < err.start) {
          err = FormulaError(FormulaErrorCode.unexpectedCharacter,
              r'Remove the $ from the number', k.start, k.end);
        }
        break;
      }
    }
  }
  if (err != null) return fail(err);
  final expr = parsed.expr!;

  final r = evaluate(expr, vars);
  if (r is EvalErr) return fail(r.error);
  final exact = (r as EvalOk).value;
  final Decimal value;
  if (spec.isInteger) {
    if (!isWhole(exact)) {
      return fail(FormulaError(
          FormulaErrorCode.notWhole,
          'Must be a whole number; this works out to ${plainDecimal(exact)}',
          expr.start,
          expr.end));
    }
    value = exact.toDecimal();
  } else {
    value = roundHalfAwayFromZero(exact, spec.scale);
  }
  final p = spec.rangeProblem(value, formula: true);
  if (p != null) {
    return fail(
        FormulaError(FormulaErrorCode.outOfRange, p, expr.start, expr.end));
  }
  return FieldResolution(
    isPlain: false,
    isFormula: true,
    value: value,
    hints: _hints(expr, spec, vars),
    canonicalText: canonical,
    referencedLower: refs,
    tokens: tokens,
  );
}

List<FormulaHint> _hints(Expr root, FieldSpec spec, VariableLookup vars) {
  final out = <FormulaHint>[];
  final hundred = Decimal.fromInt(100);
  // Variables that are the left side of `/ 100` (possibly bracketed).
  final divided = <Expr>{};
  for (final e in walkExpr(root)) {
    if (e is Binary &&
        e.op == BinaryOp.divide &&
        _bare(e.right) is NumberLit &&
        (_bare(e.right) as NumberLit).value == hundred) {
      divided.add(_bare(e.left));
    }
  }
  for (final e in walkExpr(root)) {
    if (e is! VarRef) continue;
    final v = vars.lookup(e.lowerName);
    if (v == null) continue;
    if (v.unit == VariableUnit.percent &&
        (spec.unit == FieldUnit.money || spec.unit == FieldUnit.integer) &&
        !divided.contains(e)) {
      final where = spec.unit == FieldUnit.money ? 'In an amount' : 'Here';
      out.add(FormulaHint(
          FormulaHintCode.percentInAmount,
          '\$${v.name} is a percentage (${v.value}). $where it counts as '
          '${v.value}; write \$${v.name} / 100 for ${v.value}%',
          e.start,
          e.end));
    } else if (v.unit == VariableUnit.money && spec.unit == FieldUnit.percent) {
      out.add(FormulaHint(FormulaHintCode.moneyInRate,
          '\$${v.name} is an amount, not a percentage', e.start, e.end));
    }
  }
  return out;
}

Expr _bare(Expr e) => e is Group ? _bare(e.inner) : e;
