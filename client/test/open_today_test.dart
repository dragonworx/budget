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
      Duration(microseconds: (v.days / 2 * Duration.microsecondsPerDay).round()),
    );
    // Centre of the view falls within today.
    expect(centre.isAfter(today), isTrue);
    expect(centre.isBefore(today.add(const Duration(days: 1))), isTrue);
  });

  test('currency scale range centres on today when it would be off screen',
      () {
    // Zero-anchored window −5..95 would hide a 5000 balance.
    final r = currencyScaleRange(10, 4000, 6000, focus: 5003);
    expect(r.min, 4950);
    expect(r.max, 5050);
    // When today's balance already fits, the zero-anchored window stays.
    final s = currencyScaleRange(100, 200, 500, focus: 300);
    expect(s.min, lessThanOrEqualTo(0));
    expect(s.max - s.min, closeTo(1000, 1e-9));
  });
}
