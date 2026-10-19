import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2031, 3, 1);

Future<TextSpan> _balanceSpan(WidgetTester tester, double threshold) async {
  const size = Size(600, 500);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final points = [
    for (var i = -5; i < 40; i++)
      BalancePoint(
        date: _start.add(Duration(days: i)),
        closingBalance: Decimal.fromInt(i < 10 ? 800 : 500),
      ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(
              points: points,
              occurrences: [
                Occurrence(
                  transactionId: 't1',
                  date: _start.add(const Duration(days: 10)),
                  signedDelta: Decimal.fromInt(-300),
                ),
              ],
            ),
            currency: 'AUD',
            seedDate: _start.subtract(const Duration(days: 5)),
            lossThreshold: threshold,
            viewStart: _start,
            visibleDays: 30,
            transactionNames: const {'t1': 'Rent'},
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final tip = find.byKey(const ValueKey('tip-balance'));
  final plot = tester.getRect(find.byType(BalanceChart));
  for (var fy = 0.05; fy < 0.9 && tip.evaluate().isEmpty; fy += 0.01) {
    final p = Offset(
      plot.left + plot.width * (10.5 / 30),
      plot.top + plot.height * fy,
    );
    await tester.tapAt(p, kind: PointerDeviceKind.touch);
    await tester.pump();
  }
  expect(tip, findsOneWidget, reason: 'tapping the dot shows its info');
  final span = tester.widget<Text>(tip).textSpan! as TextSpan;
  expect(span.toPlainText(), contains('500'));
  return span.children!.single as TextSpan;
}

void main() {
  testWidgets('tip balance is bold red below the alert threshold', (
    tester,
  ) async {
    final s = await _balanceSpan(tester, 1000);
    expect(s.style!.fontWeight, FontWeight.w800);
    expect(s.style!.color, AppTheme.debitColor);
  });

  testWidgets('tip balance is bold green at or above it (default 0)', (
    tester,
  ) async {
    final s = await _balanceSpan(tester, 0);
    expect(s.style!.fontWeight, FontWeight.w800);
    expect(s.style!.color, AppTheme.creditColor);
  });

  testWidgets('balance exactly at the threshold counts as green', (
    tester,
  ) async {
    final s = await _balanceSpan(tester, 500);
    expect(s.style!.color, AppTheme.creditColor);
  });
}
