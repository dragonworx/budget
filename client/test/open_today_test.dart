import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/timeline/view_units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opening view is one default unit centred on today', () {
    final today = DateTime(2026, 10, 19);
    final v = initialView(today, ViewUnit.month);
    expect(v.days, 31); // October
    final centre = v.start.add(
      Duration(
        microseconds: (v.days / 2 * Duration.microsecondsPerDay).round(),
      ),
    );
    // Centre of the view falls within today.
    expect(centre.isAfter(today), isTrue);
    expect(centre.isBefore(today.add(const Duration(days: 1))), isTrue);
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
