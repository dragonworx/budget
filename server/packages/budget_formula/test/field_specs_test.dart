import 'package:budget_formula/budget_formula.dart';
import 'package:test/test.dart';

import 'support.dart';

FieldResolution r(String id, String text) =>
    resolveField(text, fieldSpecs[id]!, stdVars);

void main() {
  test('the catalogue has every field id', () {
    expect(fieldSpecs.keys.toSet(), {
      'event.amount',
      'loan.principal',
      'stream.seed',
      'stream.threshold',
      'loan.ratePct',
      'loan.termYears',
      'loan.termMonths',
      'loan.chargeDay',
      'event.interval',
      'event.count',
      'solve.total',
      'solve.amount',
      'solve.interval',
      'solve.count',
      'goal.startBalance',
      'goal.targetBalance',
      'goal.amount',
      'goal.oneOff',
      'goal.rate',
      'goal.count',
      'goal.interval',
      'variable.value',
    });
  });

  group('event.amount', () {
    test('messages are today\'s', () {
      expect(r('event.amount', '').error!.message, 'Enter an amount');
      expect(
          r('event.amount', '0').error!.message, 'Enter an amount above zero');
      expect(r('event.amount', '-5').error!.message,
          'Use Money out instead of a negative amount');
      expect(r('event.amount', '1 - 2').error!.message,
          'Use Money out instead of a negative amount');
    });
    test('formula cap; plain numbers keep no cap', () {
      expect(r('event.amount', '999999999999.99 + 0').value,
          dec('999999999999.99'));
      expect(r('event.amount', '999999999999.99 + 0.01').error!.code,
          FormulaErrorCode.outOfRange);
      expect(r('event.amount', '5000000000000').value, dec('5000000000000'));
    });
    test('rounding to cents', () {
      expect(r('event.amount', '10 / 3').value, dec('3.33'));
      expect(r('event.amount', '20 / 3').value, dec('6.67'));
    });
  });

  test('loan.principal', () {
    expect(r('loan.principal', '').error!.message, 'Enter the amount borrowed');
    expect(r('loan.principal', '500,000').value, dec('500000'));
    expect(
        r('loan.principal', '0').error!.message, 'Enter an amount above zero');
    expect(r('loan.principal', r'rent * 400').value, dec('480000'));
  });

  test('stream.seed / threshold are signed', () {
    expect(r('stream.seed', '-120.50').value, dec('-120.5'));
    expect(r('stream.seed', r'-rent').value, dec('-1200'));
    expect(r('stream.threshold', '').value, dec('0'));
    expect(r('stream.threshold', '').isPlain, isTrue);
    expect(r('stream.threshold', '-200').value, dec('-200'));
  });

  test('loan.ratePct', () {
    expect(r('loan.ratePct', '').error!.message, 'Enter a rate');
    expect(r('loan.ratePct', '100').value, dec('100'));
    expect(r('loan.ratePct', '100.0001').isPlain, isFalse);
    expect(r('loan.ratePct', '100.0001').error!.message, 'At most 100%');
    expect(r('loan.ratePct', '0').value, dec('0'));
    expect(r('loan.ratePct', '50 * 2').value, dec('100'));
    expect(r('loan.ratePct', '1 / 3').value, dec('0.3333'));
    expect(r('loan.ratePct', '0 - 0.00001').value, dec('0'));
    expect(r('loan.ratePct', '0 - 0.0001').error!.message, 'At least 0%');
  });

  test('integer fields reject non-whole results and check ranges', () {
    expect(r('event.count', '10 / 4').error!.code, FormulaErrorCode.notWhole);
    expect(r('event.count', '10 / 4').error!.message,
        'Must be a whole number; this works out to 2.5');
    expect(r('event.count', '1 / 3').error!.message,
        'Must be a whole number; this works out to 0.3333');
    expect(r('event.count', '100000').value, dec('100000'));
    expect(r('event.count', '100001').value, dec('100001'),
        reason: 'plain: no cap');
    expect(r('event.count', '100000 + 1').error!.code,
        FormulaErrorCode.outOfRange);
    expect(r('loan.chargeDay', '31').value, dec('31'));
    expect(r('loan.chargeDay', '32').error!.message, 'A day from 1 to 31');
    expect(r('loan.chargeDay', '0').error!.message, 'A day from 1 to 31');
    expect(r('loan.termYears', '0').value, dec('0'));
    expect(r('loan.termYears', r'weeks / 2').value, dec('26'));
    expect(r('event.interval', '99').value, dec('99'));
    expect(r('event.interval', '100').error!.message, '1–99');
    expect(resolveField('1', intervalSpec(2), stdVars).error!.message, '2–99');
    expect(r('solve.interval', '').value, isNull);
    expect(r('solve.count', '0').error!.message, 'Whole number ≥ 1');
    expect(r('goal.count', '0').value, dec('0'));
    expect(r('goal.count', '-1').error!.message, 'Whole number');
  });

  test('goal fields: plain values are the double\'s, ranges stay the server\'s',
      () {
    expect(r('goal.amount', '').value, isNull);
    expect(r('goal.amount', '-5').value, dec('-5'));
    expect(r('goal.rate', '5000').value, dec('5000'), reason: 'server checks');
    expect(r('goal.rate', '2000 + 1').error!.message, 'Between 0 and 1000%');
    expect(r('goal.amount', 'abc').error, isNotNull);
  });

  test('solve fields', () {
    expect(r('solve.total', '').value, isNull);
    expect(r('solve.total', '0').error!.message, 'Must be > 0');
    expect(r('solve.total', '1,000').isPlain, isFalse,
        reason: 'Decimal.tryParse rejects commas today');
    expect(
        r('solve.total', '1,000').error!.code, FormulaErrorCode.reservedSyntax);
    expect(r('solve.amount', r'rent / 2').value, dec('600'));
  });

  test('variable.value', () {
    expect(r('variable.value', '').error!.message, 'Enter a value');
    expect(r('variable.value', '1,250.5').value, dec('1250.5'));
    expect(r('variable.value', '-1_000').value, dec('-1000'));
    expect(r('variable.value', '0.1234567891').value, dec('0.1234567891'));
    expect(r('variable.value', '0.12345678912').error!.code,
        FormulaErrorCode.tooManyDecimals);
    expect(r('variable.value', '1e999999999').isPlain, isFalse);
    expect(r('variable.value', '2 / 3').value, dec('0.6666666667'));
  });

  test('currency sigil only in money fields', () {
    expect(r('stream.seed', r'$5 * 2').value, dec('10'));
    expect(r('loan.ratePct', r'$5 * 2').error!.message,
        r'Remove the $ from the number');
    expect(r('event.count', r'$5 * 2').error!.code,
        FormulaErrorCode.unexpectedCharacter);
    // The earlier error wins.
    expect(r('event.count', r'* $5').error!.code,
        FormulaErrorCode.unexpectedToken);
  });

  test('resolution details', () {
    final x = r('event.amount', r'  RENT×2 + weeks ');
    expect(x.isFormula, isTrue);
    expect(x.canonicalText, r'rent*2 + weeks');
    expect(x.referencedLower, {'rent', 'weeks'});
    expect(x.value, dec('2452'));
    final bad = r('event.amount', r'nope * 2');
    expect(bad.canonicalText, r'nope * 2');
    expect(bad.referencedLower, {'nope'});
    expect(bad.value, isNull);
    final plain = r('event.amount', ' 1,250 ');
    expect(plain.isPlain, isTrue);
    expect(plain.canonicalText, isNull);
    expect(plain.referencedLower, isEmpty);
  });

  test('hint messages', () {
    final h = r('event.amount', r'rate * 100').hints.single;
    expect(h.message,
        r'rate is a percentage (5.5). In an amount it counts as 5.5; write rate / 100 for 5.5%');
    expect([h.start, h.end], [0, 4]);
    expect(r('loan.ratePct', r'rent / 1000').hints.single.codeName,
        'money_in_rate');
    expect(r('loan.ratePct', r'rate').hints, isEmpty);
  });

  test('format', () {
    expect(
        fieldSpecs['event.amount']!.format(dec('1234567.5')), r'$1,234,567.5');
    expect(fieldSpecs['loan.ratePct']!.format(dec('100')), '100%');
    expect(fieldSpecs['event.count']!.format(dec('-1000')), '-1,000');
  });

  test('a known variable on its own beats the legacy letter prefix', () {
    final vars = MapVariableLookup([
      VariableValue('q1', dec('300'), VariableUnit.money),
      VariableValue('abc12', dec('7'), VariableUnit.money),
    ]);
    FieldResolution rv(String id, String t) =>
        resolveField(t, fieldSpecs[id]!, vars);
    expect(rv('event.amount', 'q1').value, dec('300'));
    expect(rv('event.amount', 'q1').isFormula, isTrue);
    expect(rv('event.amount', 'Q1').canonicalText, 'q1');
    expect(rv('stream.seed', '-abc12').value, dec('-7'));
    // Unknown: today's parser still reads it (plain, unchanged).
    expect(rv('event.amount', 'q2').isPlain, isTrue);
    expect(rv('event.amount', 'q2').value, dec('2'));
    expect(rv('event.amount', 'AUD1250').value, dec('1250'));
  });
}
