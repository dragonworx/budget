import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/saved_view.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/timeline/view_units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opening view is one default unit centred on today', () {
    final today = DateTime(2026, 10, 19);
    final v = initialView(today, ViewUnit.month);
    expect(v.days, 31); // October
    expect(v.start, viewStartCenteredOn(today, v.days));
    // The Today line sits on the day's start, at the window's centre.
    expect(addDays(v.start, v.days / 2), today);
  });

  test('a saved view keeps its span and scale, recentred on today', () {
    final today = DateTime(2026, 11, 26);
    final v = SavedView(
      start: dayCoord(DateTime(2024, 1, 1)),
      days: 91.31,
      unit: ViewUnit.quarter,
      yMin: -500,
      yMax: 4000,
    );
    final c = centerViewOnToday(v, today);
    expect(c.days, 91.31);
    expect(c.unit, ViewUnit.quarter);
    expect((c.yMin, c.yMax), (-500.0, 4000.0));
    expect(c.start, isNot(v.start));
    expect(c.start, dayCoord(viewStartCenteredOn(today, v.days)));
    expect(addDays(c.startDate, c.days / 2), today);
  });

  test('default view keeps today\'s balance in view with zero at 1/3', () {
    // Formerly the window re-centred on a far-off balance; now the span
    // widens so the data (today's balance included) fits above zero.
    final r = currencyScaleRange(10, 4000, 6000);
    expect(r.min, lessThan(0));
    expect(r.max, greaterThan(5003));
    expect(-r.min / (r.max - r.min), closeTo(1 / 3, 1e-9));
  });
}
