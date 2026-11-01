import 'dart:convert';
import 'dart:io';

import 'package:budget_client/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

// The pre-delegation parseMoneyInput, verbatim (client/lib/widgets/
// money_text.dart L35, HEAD e429c1b): the oracle proving it is unchanged.
Decimal? oracleParseMoneyInput(String input) {
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

void main() {
  test('parseMoneyInput is unchanged on the budget_formula legacy corpus', () {
    final corpus = (jsonDecode(
      File('../server/packages/budget_formula/test/legacy_corpus.json')
          .readAsStringSync(),
    ) as List).cast<String>();
    expect(corpus.length, greaterThanOrEqualTo(200));
    var accepted = 0;
    for (final s in corpus) {
      final want = oracleParseMoneyInput(s);
      expect(parseMoneyInput(s), want, reason: jsonEncode(s));
      if (want != null) accepted++;
    }
    expect(accepted, greaterThan(20));
  });

  test('spot checks', () {
    expect(parseMoneyInput(r'A$1,250.50'), Decimal.parse('1250.5'));
    expect(parseMoneyInput(r'$-5'), Decimal.parse('-5'));
    expect(parseMoneyInput('-1 200'), Decimal.parse('-1200'));
    expect(parseMoneyInput('1_000'), Decimal.parse('1000'));
    expect(parseMoneyInput('5.'), isNull);
    expect(parseMoneyInput('1e3'), isNull);
    expect(parseMoneyInput(''), isNull);
  });
}
