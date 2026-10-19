// Dot labels: the day's net transaction total (no "A" country prefix) on
// top, then each transaction's name in the order added; no count badge;
// "+N more" when the list doesn't fit. Labels never overlap.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

typedef _Txn = (int day, int delta, String name, {bool skipped});

Transaction _t(String id, String name) => Transaction(
  id: id,
  accountId: 'a',
  name: name,
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(10),
  startDate: _start,
  recurrenceMode: RecurrenceMode.once,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: EndMode.never,
);

Future<List<(Rect, List<String>)>> _labels(
  WidgetTester tester,
  Size size,
  List<_Txn> txns, {
  List<String>? creationOrder,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  final names = <String, String>{};
  final occ = <Occurrence>[];
  final points = <BalancePoint>[];
  var bal = 1000;
  for (var i = 0; i < 60; i++) {
    final d = _start.add(Duration(days: i));
    for (final (day, delta, name, :skipped) in txns) {
      if (day != i) continue;
      names[name] = name;
      occ.add(
        Occurrence(
          transactionId: name,
          date: d,
          signedDelta: Decimal.fromInt(delta),
          skipped: skipped,
        ),
      );
      if (!skipped) bal += delta;
    }
    points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(bal)));
  }
  final out = <(Rect, List<String>)>[];
  debugVertexLabelLines = (rect, lines) => out.add((rect, lines));
  await tester.pumpWidget(const SizedBox());
  out.clear();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(points: points, occurrences: occ),
            seedDate: _start.subtract(const Duration(days: 60)),
            viewStart: _start,
            visibleDays: 30,
            transactionNames: names,
            transactions: {
              for (final id in creationOrder ?? const <String>[])
                id: _t(id, id),
            },
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  debugVertexLabelLines = null;
  return out;
}

List<String>? _labelStarting(List<(Rect, List<String>)> labels, String total) {
  for (final (_, lines) in labels) {
    if (lines.first == total) return lines;
  }
  return null;
}

void _expectNoOverlap(List<(Rect, List<String>)> labels) {
  for (var i = 0; i < labels.length; i++) {
    for (var j = i + 1; j < labels.length; j++) {
      expect(
        labels[i].$1.overlaps(labels[j].$1),
        isFalse,
        reason: '${labels[i].$2} overlaps ${labels[j].$2}',
      );
    }
  }
}

void main() {
  tearDown(() => debugVertexLabelLines = null);

  test('money is a plain "\$" everywhere; input still accepts a prefix', () {
    expect(moneySymbol, r'$');
    expect(formatSignedAmount(-180), r'−$180');
    expect(formatSignedAmount(2400), r'+$2,400');
    expect(formatMoneyAmount(250), r'$250');
    expect(formatMoneyAmount(12.5), r'$12.50');
    expect(formatSignedAmount(1.36e6), r'+$1.36M');
    expect(parseMoneyInput(r'A$1,250.50'), Decimal.parse('1250.50'));
    expect(parseMoneyInput(r'$1,250.50'), Decimal.parse('1250.50'));
    expect(parseMoneyInput(r'-A$20'), Decimal.parse('-20'));
  });

  testWidgets('a multi-transaction day shows its net total, then each name '
      'in the order added; no badge, no balance', (tester) async {
    addTearDown(tester.view.reset);
    final labels = await _labels(
      tester,
      const Size(1440, 800),
      [
        (5, 2400, 'Salary', skipped: false),
        (12, -180, 'Zeta gym', skipped: false),
        (12, -50, 'Alpha coffee', skipped: false),
        (12, 1000, 'Bonus', skipped: false),
        (12, -999, 'Skipped rent', skipped: true),
      ],
      creationOrder: ['Salary', 'Bonus', 'Zeta gym', 'Alpha coffee'],
    );
    // Net of the counted occurrences: 1000 − 180 − 50 (skipped excluded).
    expect(_labelStarting(labels, r'+$770'), [
      r'+$770',
      'Bonus',
      'Zeta gym',
      'Alpha coffee',
    ]);
    expect(_labelStarting(labels, r'+$2,400'), [r'+$2,400', 'Salary']);
    for (final (_, lines) in labels) {
      for (final l in lines) {
        expect(l.contains(r'A$'), isFalse, reason: l);
        // No count badge line ("2", "3" ...).
        expect(RegExp(r'^\d+$').hasMatch(l), isFalse, reason: l);
      }
    }
    _expectNoOverlap(labels);
  });

  testWidgets('without creation order, names follow the order first seen', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final labels = await _labels(tester, const Size(1440, 800), [
      (12, -180, 'Zeta gym', skipped: false),
      (12, -50, 'Alpha coffee', skipped: false),
    ]);
    expect(_labelStarting(labels, r'−$230'), [
      r'−$230',
      'Zeta gym',
      'Alpha coffee',
    ]);
  });

  testWidgets('a long list that does not fit shows "+N more"', (tester) async {
    addTearDown(tester.view.reset);
    final labels = await _labels(tester, const Size(1440, 330), [
      for (var i = 0; i < 9; i++) (12, -100, 'Item $i', skipped: false),
    ]);
    final lines = _labelStarting(labels, r'−$900');
    expect(lines, isNotNull);
    expect(lines!.last, matches(RegExp(r'^\+\d+ more$')));
    final listed = lines.length - 2;
    expect(listed, lessThanOrEqualTo(maxLabelNames));
    expect(lines.last, '+${9 - listed} more');
    expect(lines.sublist(1, 1 + listed), [
      for (var i = 0; i < listed; i++) 'Item $i',
    ]);
  });

  testWidgets('crowded multi-transaction days never overlap', (tester) async {
    addTearDown(tester.view.reset);
    for (final size in const [Size(390, 700), Size(1440, 800)]) {
      final labels = await _labels(tester, size, [
        for (var d = 2; d < 28; d++) ...[
          (d, d.isEven ? 400 : -350, 'Item $d', skipped: false),
          if (d % 3 == 0) (d, -25, 'Extra $d', skipped: false),
        ],
      ]);
      expect(labels.length, greaterThan(3));
      _expectNoOverlap(labels);
    }
  });
}
