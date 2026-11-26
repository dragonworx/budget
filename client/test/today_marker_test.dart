// DEV-11: today's closing balance lives in the existing "Today" label
// at the top of the today marker line (not the footer / date lanes).
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_client/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('todayMarkerText keeps "Today" and appends the amount', () {
    expect(todayMarkerText(null, plotWidth: 1440), 'Today');
    expect(
      todayMarkerText(6400, plotWidth: 1440),
      'Today · ${formatMoneyAmount(6400, decimalDigits: 2)}',
    );
    expect(todayMarkerText(6400, plotWidth: 1440), 'Today · \$6,400.00');
    // Narrow phones drop cents from \$10,000 up.
    expect(todayMarkerText(10000, plotWidth: 1440), 'Today · \$10,000.00');
    expect(todayMarkerText(10000, plotWidth: 320), 'Today · \$10,000');
    expect(todayMarkerText(6400, plotWidth: 320), 'Today · \$6,400.00');
    expect(
      todayMarkerText(-250.5, plotWidth: 1440),
      'Today · ${formatMoneyAmount(-250.5, decimalDigits: 2)}',
    );
  });

  test('closingBalanceOnDay uses the last point on or before the day', () {
    final points = [
      BalancePoint(
        date: DateTime(2026, 11, 1),
        closingBalance: Decimal.parse('100'),
      ),
      BalancePoint(
        date: DateTime(2026, 11, 3),
        closingBalance: Decimal.parse('6400'),
      ),
      BalancePoint(
        date: DateTime(2026, 11, 5),
        closingBalance: Decimal.parse('7000'),
      ),
    ];
    expect(closingBalanceOnDay(points, DateTime(2026, 10, 31)), isNull);
    expect(closingBalanceOnDay(points, DateTime(2026, 11, 1)), 100);
    expect(closingBalanceOnDay(points, DateTime(2026, 11, 2)), 100);
    expect(closingBalanceOnDay(points, DateTime(2026, 11, 3)), 6400);
    expect(closingBalanceOnDay(points, DateTime(2026, 11, 10)), 7000);
    expect(closingBalanceOnDay(const [], DateTime(2026, 11, 3)), isNull);
  });

  testWidgets('the Today chip at the top of the line shows today\'s balance', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    String? text;
    Color? amountColor;
    Rect? rect;
    debugTodayMarkerLabel = (t, c, r) {
      text = t;
      amountColor = c;
      rect = r;
    };
    addTearDown(() => debugTodayMarkerLabel = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1440,
            height: 800,
            child: BalanceChart(
              series: BalanceSeries(
                points: [
                  for (var i = -10; i <= 10; i++)
                    BalancePoint(
                      date: today.add(Duration(days: i)),
                      closingBalance: Decimal.parse(i == 0 ? '6400' : '1000'),
                    ),
                ],
              ),
              seedDate: today.subtract(const Duration(days: 30)),
              viewStart: today.subtract(const Duration(days: 15)),
              visibleDays: 40,
              lossThreshold: 0,
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(text, 'Today · \$6,400.00');
    expect(amountColor, isNot(AppTheme.debitColor));
    expect(rect, isNotNull);
    final chart = tester.getRect(find.byType(BalanceChart));
    // Top of the plot, not the footer date lanes.
    expect(rect!.top, lessThan(chart.top + 40));
    expect(rect!.bottom, lessThan(chart.center.dy));
  });

  testWidgets('a negative today balance uses the debit colour', (tester) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    Color? amountColor;
    String? text;
    debugTodayMarkerLabel = (t, c, _) {
      text = t;
      amountColor = c;
    };
    addTearDown(() => debugTodayMarkerLabel = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1440,
            height: 800,
            child: BalanceChart(
              series: BalanceSeries(
                points: [
                  BalancePoint(
                    date: today,
                    closingBalance: Decimal.parse('-250.50'),
                  ),
                ],
              ),
              seedDate: today.subtract(const Duration(days: 5)),
              viewStart: today.subtract(const Duration(days: 10)),
              visibleDays: 30,
              lossThreshold: 0,
              alerts: true,
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(text, 'Today · ${formatMoneyAmount(-250.5, decimalDigits: 2)}');
    expect(amountColor, AppTheme.debitColor);
  });

  testWidgets('today off-screen draws no Today label', (tester) async {
    tester.view.physicalSize = const Size(1440, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    var called = false;
    debugTodayMarkerLabel = (_, _, _) => called = true;
    addTearDown(() => debugTodayMarkerLabel = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1440,
            height: 800,
            child: BalanceChart(
              series: BalanceSeries(
                points: [
                  BalancePoint(
                    date: today.subtract(const Duration(days: 60)),
                    closingBalance: Decimal.parse('6400'),
                  ),
                ],
              ),
              seedDate: today.subtract(const Duration(days: 90)),
              viewStart: today.subtract(const Duration(days: 80)),
              visibleDays: 20,
              onViewportChanged: (_, _) {},
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(called, isFalse);
  });
}
