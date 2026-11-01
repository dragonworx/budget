import 'dart:convert';
import 'dart:io';

import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Oracles: today's code, copied verbatim (HEAD e429c1b).
// ---------------------------------------------------------------------------

// client/lib/widgets/money_text.dart L35 parseMoneyInput.
Decimal? oracleMoney(String input) {
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

// client/lib/features/loans/rate_periods_editor.dart L54 rateTextError.
String? oracleRateTextError(String text) {
  final t = text.trim();
  if (t.isEmpty) return 'Enter a rate';
  if (!RegExp(r'^\d{1,3}(\.\d{1,4})?$').hasMatch(t)) {
    return 'A number like 6.4 (up to 4 decimals)';
  }
  if (double.parse(t) > 100) return 'At most 100%';
  return null;
}

// client/lib/features/events/solve_sheet.dart L154 _parseMoney (+ L162).
Decimal? oracleSolveMoney(String text) => Decimal.tryParse(text.trim());

// client/lib/features/planning/goal_panel.dart L208 _num / L236.
double? oracleGoal(String text) => double.tryParse(text.trim());

// client/lib/features/loans/loan_form.dart L311-L316 (validator) and
// loan_models.dart L277 principalValue (the value sent).
String? oraclePrincipalError(String? v) {
  final t = (v ?? '').trim();
  if (t.isEmpty) return 'Enter the amount borrowed';
  final n = double.tryParse(t.replaceAll(',', ''));
  if (n == null) return 'Enter a number, e.g. 500000';
  if (n <= 0) return 'Enter an amount above zero';
  return null;
}

Decimal? oraclePrincipalValue(String principal) {
  final v = Decimal.tryParse(principal.trim().replaceAll(',', ''));
  return v == null || v <= Decimal.zero ? null : v;
}

// int.tryParse(text.trim()) (frequency_picker.dart L146, event_editor.dart
// L1336 without trim, loan_form.dart L592, solve_sheet.dart L171,
// goal_panel.dart L229).
int? oracleInt(String text) => int.tryParse(text.trim());

void main() {
  final corpus =
      (jsonDecode(File('test/legacy_corpus.json').readAsStringSync()) as List)
          .cast<String>();

  test('corpus has at least 200 inputs', () {
    expect(corpus.length, greaterThanOrEqualTo(200));
  });

  test('parseLegacyMoney == parseMoneyInput on the whole corpus', () {
    for (final s in corpus) {
      expect(parseLegacyMoney(s), oracleMoney(s), reason: jsonEncode(s));
    }
  });

  test('parseLegacyRate accepts exactly what rateTextError accepts', () {
    for (final s in corpus) {
      final ok = oracleRateTextError(s) == null;
      final got = parseLegacyRate(s);
      expect(got != null, ok, reason: jsonEncode(s));
      if (ok) expect(got, Decimal.parse(s.trim()), reason: jsonEncode(s));
    }
  });

  test('parseLegacyDecimalRaw == Decimal.tryParse(trim)', () {
    for (final s in corpus) {
      expect(parseLegacyDecimalRaw(s), oracleSolveMoney(s),
          reason: jsonEncode(s));
    }
  });

  test(
      'parseLegacyDoubleRaw: what double.tryParse accepts, NaN/Infinity '
      'excepted (the one intended deviation)', () {
    var deviations = 0;
    for (final s in corpus) {
      final d = oracleGoal(s);
      final got = parseLegacyDoubleRaw(s);
      if (d != null && !d.isFinite) {
        expect(got, isNull, reason: jsonEncode(s));
        deviations++;
        continue;
      }
      expect(got != null, d != null, reason: jsonEncode(s));
      if (d != null) {
        // The value sent today is the double; ours is its exact shortest
        // decimal, which converts back to the same double.
        expect(double.parse(got.toString()), d, reason: jsonEncode(s));
        expect(got, Decimal.parse(_shortest(d)), reason: jsonEncode(s));
      }
    }
    expect(deviations, greaterThan(0), reason: 'corpus covers NaN/Infinity');
  });

  test('parseLegacyPrincipal: the validator\'s accepted set, the sent value',
      () {
    for (final s in corpus) {
      final err = oraclePrincipalError(s);
      final got = parseLegacyPrincipal(s);
      final n = double.tryParse(s.trim().replaceAll(',', ''));
      if (n != null && !n.isFinite) {
        expect(got, isNull, reason: jsonEncode(s));
        continue;
      }
      // Accepted (any sign: the > 0 rule is the field spec's).
      final parsed = err == null || err == 'Enter an amount above zero';
      expect(got != null, parsed, reason: jsonEncode(s));
      if (err == null) {
        final sent = oraclePrincipalValue(s);
        if (sent != null) expect(got, sent, reason: jsonEncode(s));
      }
    }
  });

  test('parseLegacyInt == int.tryParse(trim) (and untrimmed call sites)', () {
    for (final s in corpus) {
      expect(parseLegacyInt(s), oracleInt(s), reason: jsonEncode(s));
      // event_editor L1336 / loan_form L592 don't trim: int.tryParse
      // ignores surrounding whitespace itself.
      expect(int.tryParse(s), oracleInt(s), reason: jsonEncode(s));
    }
  });

  test('the corpus\'s NaN / Infinity rows (recorded deviation)', () {
    for (final s in ['NaN', 'Infinity', '-Infinity', ' NaN', 'NaN ']) {
      expect(corpus, contains(s));
      expect(double.tryParse(s.trim()), isNotNull);
      expect(parseLegacyDoubleRaw(s), isNull);
      expect(parseLegacyPrincipal(s), isNull);
      final r =
          resolveField(s, fieldSpecs['goal.amount']!, VariableLookup.none);
      expect(r.isPlain, isFalse);
      expect(r.error, isNotNull);
    }
  });

  test('every plain input a field accepts today resolves as plain', () {
    final cases = <String, bool Function(String)>{
      'event.amount': (s) => oracleMoney(s) != null,
      'stream.seed': (s) => oracleMoney(s) != null,
      'loan.ratePct': (s) => oracleRateTextError(s) == null,
      'solve.total': (s) => oracleSolveMoney(s) != null,
      'event.count': (s) => oracleInt(s) != null,
    };
    for (final MapEntry(key: id, value: acceptedToday) in cases.entries) {
      final spec = fieldSpecs[id]!;
      for (final s in corpus) {
        if (s.trim().isEmpty || !acceptedToday(s)) continue;
        final r = resolveField(s, spec, VariableLookup.none);
        expect(r.isPlain, isTrue, reason: '$id ${jsonEncode(s)} $r');
        expect(r.canonicalText, isNull);
      }
    }
  });
}

String _shortest(double d) {
  final s = d.toString();
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$').firstMatch(s)!;
  final digits = '${m[2]}${m[3] ?? ''}';
  final exp = int.parse(m[4] ?? '0') - (m[3]?.length ?? 0);
  final v = Decimal.parse(digits).shift(exp);
  return (m[1] == '-' ? -v : v).toString();
}
