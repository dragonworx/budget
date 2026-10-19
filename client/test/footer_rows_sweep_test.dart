// Regression: every date-axis label is painted inside its own row (Year,
// Month, Week, Day) at every zoom and viewport width, clear of the row-name
// chip, never overlapping a neighbour, and the Week row only ever shows the
// ISO week number ("Week 42" / "W42"), never a date or bare day numeral.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _start = DateTime(2026, 10, 5);
const _widths = [280.0, 320.0, 390.0, 599.0, 700.0, 1024.0, 1440.0, 2560.0];
const _zooms = [
  2.0,
  3.0,
  7.0,
  14.0,
  31.0,
  60.0,
  91.0,
  182.0,
  365.0,
  730.0,
  1825.0,
  3650.0,
];

Future<List<(String, String, Rect)>> _paint(
  WidgetTester tester,
  Size size,
  double days,
  double textScale,
) async {
  final labels = <(String, String, Rect)>[];
  debugAxisLabel = (row, text, rect) => labels.add((row, text, rect));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: BalanceSeries(
              points: [
                for (var i = 0; i < 40; i++)
                  BalancePoint(
                    date: _start.add(Duration(days: i)),
                    closingBalance: Decimal.fromInt(500 + i * 10),
                  ),
              ],
              occurrences: const [],
            ),
            seedDate: _start,
            viewStart: _start,
            visibleDays: days,
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  debugAxisLabel = null;
  return labels;
}

void main() {
  tearDown(() => debugAxisLabel = null);

  testWidgets('every axis label stays inside its own row at all zooms × '
      'widths', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final seen = <String, int>{};
    for (final scale in const [1.0, 1.3]) {
      for (final width in _widths) {
        final size = Size(width, 600);
        for (final days in _zooms) {
          final where = '${width.toInt()}px × ${days}d @${scale}x';
          final layout = ChartLayout.of(size, days);
          final bands = {
            'Year': layout.yearBand,
            'Month': layout.monthBand,
            'Week': layout.weekBand!,
            'Day': layout.dayBand!,
          };
          final nameW = width < 600 ? 38.0 : 44.0;
          final labels = await _paint(tester, size, days, scale);
          final byRow = <String, List<Rect>>{};
          for (final (row, text, rect) in labels) {
            seen[row] = (seen[row] ?? 0) + 1;
            final band = bands[row]!;
            final ctx = '$row "$text" $rect in $band at $where';
            expect(rect.top, greaterThanOrEqualTo(band.top - 0.5), reason: ctx);
            expect(
              rect.bottom,
              lessThanOrEqualTo(band.bottom + 0.5),
              reason: ctx,
            );
            expect(
              rect.left,
              greaterThanOrEqualTo(band.left + nameW - 0.5),
              reason: '$ctx (under the row name)',
            );
            expect(
              rect.right,
              lessThanOrEqualTo(band.right + 0.5),
              reason: ctx,
            );
            if (row == 'Week') {
              // Always the ISO week number, in full, never a date or a bare
              // numeral (both read as days).
              expect(
                RegExp(r'^(Week |W)([1-9]|[1-4]\d|5[0-3])$').hasMatch(text),
                isTrue,
                reason: '$ctx: not a week number',
              );
            }
            if (row != 'Day') byRow.putIfAbsent(row, () => []).add(rect);
          }
          // Neighbouring labels in a row never overlap.
          for (final rects in byRow.values) {
            rects.sort((a, b) => a.left.compareTo(b.left));
            for (var i = 1; i < rects.length; i++) {
              expect(
                rects[i].left,
                greaterThanOrEqualTo(rects[i - 1].right - 0.5),
                reason: 'overlap at $where',
              );
            }
          }
          // Day labels: one numeral per labelled day, never overlapping.
          final dayNums = [
            for (final (row, text, rect) in labels)
              if (row == 'Day' && RegExp(r'^\d').hasMatch(text)) rect,
          ]..sort((a, b) => a.left.compareTo(b.left));
          for (var i = 1; i < dayNums.length; i++) {
            expect(
              dayNums[i].left,
              greaterThanOrEqualTo(dayNums[i - 1].right),
              reason: 'day labels overlap at $where',
            );
          }
        }
      }
    }
    // The sweep actually exercised every row.
    for (final row in const ['Year', 'Month', 'Week', 'Day']) {
      expect(seen[row] ?? 0, greaterThan(0), reason: row);
    }
  });
}
