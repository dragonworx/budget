import 'dart:convert';
import 'dart:io';

import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final rows =
      (jsonDecode(File('test/grammar_table.json').readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();

  test('the table has at least 150 rows', () {
    expect(rows.length, greaterThanOrEqualTo(150));
  });

  for (final (i, row) in rows.indexed) {
    final text = row['text'] as String;
    final field = row['field'] as String?;
    final ex = row['expect'] as Map<String, dynamic>;
    final label =
        text.length > 40 ? '${text.substring(0, 40)}… (${text.length})' : text;
    test('#$i ${field ?? 'raw'}: ${jsonEncode(label)}', () {
      FormulaError? err;
      if (field == null) {
        final p = parseFormula(text);
        err = p.error;
        if (err == null) {
          final r = evaluate(p.expr!, stdVars);
          if (r is EvalErr) {
            err = r.error;
          } else if (ex.containsKey('value')) {
            expect((r as EvalOk).value, rat(ex['value'] as String));
          }
        }
      } else {
        final spec = fieldSpecs[field]!;
        final r = resolveField(text, spec, stdVars);
        err = r.error;
        if (ex.containsKey('plain')) {
          expect(r.isPlain, isTrue, reason: '$r');
          expect(r.error, isNull, reason: '$r');
          final want = ex['plain'] as String;
          expect(r.value, want == 'null' ? isNull : dec(want));
        } else if (ex.containsKey('value')) {
          expect(r.error, isNull, reason: '$r');
          expect(r.isFormula, isTrue);
          expect(r.value, dec(ex['value'] as String));
          if (ex.containsKey('canonical')) {
            expect(r.canonicalText, ex['canonical']);
          }
          if (ex.containsKey('hints')) {
            expect([for (final h in r.hints) h.codeName], ex['hints']);
          }
        }
      }
      if (ex.containsKey('error')) {
        expect(err, isNotNull, reason: 'expected ${ex['error']}');
        expect(err!.codeName, ex['error'], reason: '$err');
        expect(err.start, ex['start'], reason: '$err');
        expect(err.end, ex['end'], reason: '$err');
        if (ex.containsKey('message')) expect(err.message, ex['message']);
        if (ex.containsKey('hint')) expect(err.hint, ex['hint']);
      } else {
        expect(err, isNull, reason: '$err');
      }
    });
  }
}
