import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';

void main() {
  test('footer always has year, month, week, day rows in order', () {
    for (final size in const [Size(390, 600), Size(1440, 700)]) {
      for (final days in const [1.0, 31.0, 91.0, 365.0, 3650.0]) {
        final l = ChartLayout.of(size, days);
        expect(l.yearBand.top, l.plot.bottom);
        expect(l.monthBand.top, l.yearBand.bottom);
        expect(l.weekBand!.top, l.monthBand.bottom);
        expect(l.dayBand!.top, l.weekBand!.bottom);
        expect(l.dayBand!.bottom, closeTo(size.height, 0.01));
      }
    }
  });
  test('year labels shorten then blank', () {
    expect(yearLabel(2026, 80), '2026');
    expect(yearLabel(2026, 24), '\u201926');
    expect(yearLabel(2026, 10), '');
  });
  test('month labels: full, 3-letter, letter, blank', () {
    final oct = DateTime(2026, 10);
    expect(monthLabel(oct, 200), 'October');
    expect(monthLabel(oct, 40), 'Oct');
    expect(monthLabel(oct, 14), 'O');
    expect(monthLabel(oct, 6), '');
  });
  test('week labels are always the ISO week number', () {
    final mon = DateTime(2026, 10, 12);
    expect(weekLabel(mon, 80), 'Week 42');
    expect(weekLabel(mon, 52), 'W42');
    expect(weekLabel(mon, 100, measure: (t) => t.length * 20.0), 'W42');
    expect(weekLabel(mon, 50, measure: (t) => t.length * 20.0), '');
    expect(weekLabel(mon, 40), 'W42');
    expect(weekLabel(mon, 24), '');
    expect(weekLabel(DateTime(2026, 12, 28), 80), 'Week 53');
    expect(isoWeekNumber(DateTime(2026, 1, 1)), 1);
    expect(isoWeekNumber(DateTime(2027, 1, 1)), 53);
    expect(isoWeekNumber(DateTime(2024, 12, 30)), 1);
    expect(weekLabel(mon, 8), '');
  });
}
