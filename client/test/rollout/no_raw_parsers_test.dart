// Spec 013 "grep check": numeric fields read their value through
// FormulaEditingController / budget_formula's legacy parsers, never by
// parsing controller text directly. Every remaining raw parser call in
// lib/ must be one of the listed exceptions (stored JSON/model values,
// prefs, ids), so a new one fails here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _raw = RegExp(
  r'parseMoneyInput\(|double\.tryParse\(|int\.tryParse\(|Decimal\.tryParse\(',
);

/// file → why its raw parses are allowed (each with the exact line text).
const _allowed = <String, List<String>>{
  // A session counter, not a field.
  'lib/boot/app_version.dart': ['int.tryParse(page.sessionGet('],
  // Saved numbers behind a flagged formula (stored values).
  'lib/features/loans/loan_form.dart': [
    'Decimal.tryParse(p.rate)',
    'Decimal.tryParse(d.principal)',
  ],
  // The loan draft's stored principal string (the field keeps its formula
  // in principalExpr; group B) and loan JSON.
  'lib/features/loans/loan_models.dart': [
    "Decimal.tryParse('\$v')",
    "Decimal.tryParse(principal.trim().replaceAll(',', ''))",
  ],
  'lib/features/loans/loan_display.dart': ["Decimal.tryParse(p?.rate ?? '')"],
  // Server JSON.
  'lib/data/models.dart': ["double.tryParse(low['balance'].toString())"],
  'lib/features/planning/goal_models.dart': [
    'double.tryParse(j[k].toString())',
    "int.tryParse('\${j[k]}')",
    "double.tryParse('\${w['closingBalance']}')",
    "double.tryParse('\${j[k]}')",
    "double.tryParse('\${low['closingBalance']}')",
  ],
  // Realtime message ids.
  'lib/data/realtime_service.dart': [
    'int.tryParse(value)',
    'int.tryParse(v.toString())',
    'int.tryParse(f.id!)',
  ],
  // Stored prefs.
  'lib/state/app_prefs.dart': ["double.tryParse(getString(key) ?? '')"],
  // Variable values/exprs from the server (display and compare).
  'lib/features/variables/variable_impact.dart': ['Decimal.tryParse(raw)'],
  'lib/features/variables/variables_manager.dart': [
    'Decimal.tryParse(a.trim())',
    'Decimal.tryParse(v.expr.trim())',
  ],
  // The legacy wrapper itself, and a doc comment.
  'lib/widgets/money_text.dart': ['parseMoneyInput(String input)'],
  'lib/widgets/formula/formula_controller.dart': [
    "today's `int.tryParse(text.trim())`",
  ],
};

void main() {
  test('no raw numeric parsing of field text outside budget_formula', () {
    final bad = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final path = f.path.replaceAll(r'\', '/');
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (!_raw.hasMatch(l)) continue;
        final ok = (_allowed[path] ?? const []).any(l.contains);
        if (!ok) bad.add('$path:${i + 1}: ${l.trim()}');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  });
}
