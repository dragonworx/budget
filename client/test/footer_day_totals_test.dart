// Footer date popup: the pinned day line shows that day's money in (green)
// and out (red) and its closing balance (green / red by the strict alert
// rule), with + and ✂ still working.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 1);
const _days = 30.0;
const _size = Size(1000, 500);

Transaction _t(String id, {bool enabled = true}) => Transaction(
  id: id,
  accountId: 'a',
  name: id,
  direction: TransactionDirection.debit,
  amount: Decimal.fromInt(10),
  startDate: _start,
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: EndMode.never,
  enabled: enabled,
);

Occurrence _o(String id, int day, int delta, {bool skipped = false}) =>
    Occurrence(
      transactionId: id,
      date: DateTime(2026, 10, day),
      signedDelta: Decimal.fromInt(delta),
      skipped: skipped,
    );

Future<List<DateTime>> _pump(
  WidgetTester tester, {
  required int balanceOn5th,
  double threshold = 0,
}) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  final created = <DateTime>[];
  final points = [
    for (var i = 0; i < 60; i++)
      BalancePoint(
        date: _start.add(Duration(days: i)),
        closingBalance: Decimal.fromInt(i == 4 ? balanceOn5th : 500),
      ),
  ];
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: _size,
          child: BalanceChart(
            series: BalanceSeries(
              points: points,
              occurrences: [
                _o('pay', 5, 2400),
                _o('gift', 5, 50),
                // A once-off override arrives as the occurrence's delta.
                _o('rent', 5, -400),
                _o('coffee', 5, -6),
                _o('skipped', 5, -1000, skipped: true),
                _o('off', 5, -77),
                _o('rent', 12, -180),
              ],
            ),
            transactions: {
              for (final id in ['pay', 'gift', 'rent', 'coffee', 'skipped'])
                id: _t(id),
              'off': _t('off', enabled: false),
            },
            currency: 'AUD',
            seedDate: _start,
            lossThreshold: threshold,
            viewStart: _start,
            visibleDays: _days,
            onViewportChanged: (_, _) {},
            onCreateOnDay: created.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return created;
}

ChartLayout get _layout => ChartLayout.of(_size, _days);
double _x(int dayIndex) =>
    _layout.plot.left + (dayIndex + 0.5) / _days * _layout.plot.width;

String _plain(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).textSpan!.toPlainText();

Color? _colorOf(WidgetTester tester, String key, String part) {
  Color? found;
  tester.widget<Text>(find.byKey(ValueKey(key))).textSpan!.visitChildren((s) {
    if (s is TextSpan && s.text == part) found = s.style?.color;
    return true;
  });
  return found;
}

void main() {
  testWidgets('pinned day shows gains, losses and balance; + still adds', (
    tester,
  ) async {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      final created = await _pump(tester, balanceOn5th: 2994);
      await tester.tapAt(Offset(_x(4), _layout.axis.center.dy), kind: kind);
      await tester.pump(const Duration(seconds: 1));
      expect(created, isEmpty, reason: 'a tap never creates');
      // Skipped and disabled occurrences don't count.
      expect(_plain(tester, 'pick-day-totals'), '+A\$2,450  ·  −A\$406');
      expect(
        _colorOf(tester, 'pick-day-totals', '+A\$2,450'),
        AppTheme.creditColor,
      );
      expect(
        _colorOf(tester, 'pick-day-totals', '−A\$406'),
        AppTheme.debitColor,
      );
      expect(
        _plain(tester, 'pick-day-balance'),
        'Balance end of day: A\$2,994',
      );
      expect(
        _colorOf(tester, 'pick-day-balance', 'A\$2,994'),
        AppTheme.creditColor,
      );
      await tester.tap(find.byKey(const ValueKey('pick-add')), kind: kind);
      await tester.pump();
      expect(created, [DateTime(2026, 10, 5)]);
    }
  });

  testWidgets('balance colour uses the strict < alert rule', (tester) async {
    Future<Color?> colour(int balance, double threshold) async {
      await _pump(tester, balanceOn5th: balance, threshold: threshold);
      await tester.tapAt(Offset(_x(4), _layout.axis.center.dy));
      await tester.pump();
      final text = _plain(tester, 'pick-day-balance').split(': ').last;
      return _colorOf(tester, 'pick-day-balance', text);
    }

    expect(await colour(0, 0), AppTheme.creditColor, reason: 'equal is fine');
    expect(await colour(-1, 0), AppTheme.debitColor);
    expect(await colour(100, 100), AppTheme.creditColor);
    expect(await colour(99, 100), AppTheme.debitColor);
  });

  testWidgets('a quiet day shows zero totals (faint)', (tester) async {
    await _pump(tester, balanceOn5th: 10);
    await tester.tapAt(Offset(_x(8), _layout.axis.center.dy));
    await tester.pump();
    expect(_plain(tester, 'pick-day-totals'), '+A\$0  ·  −A\$0');
    expect(_colorOf(tester, 'pick-day-totals', '+A\$0'), AppTheme.textFaint);
    expect(_plain(tester, 'pick-day-balance'), 'Balance end of day: A\$500');
  });
}
