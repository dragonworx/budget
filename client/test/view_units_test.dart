import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/view_units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('month arithmetic clamps to month end', () {
    expect(addMonthsClamped(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
    expect(addMonthsClamped(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29));
    expect(addMonthsClamped(DateTime(2026, 3, 31), -1), DateTime(2026, 2, 28));
    expect(addMonthsClamped(DateTime(2026, 12, 15), 1), DateTime(2027, 1, 15));
    expect(addMonthsClamped(DateTime(2026, 1, 15), -1), DateTime(2025, 12, 15));
    expect(addMonthsClamped(DateTime(2028, 2, 29), 12), DateTime(2029, 2, 28));
  });

  test('units align to calendar starts', () {
    final d = DateTime(2026, 8, 20, 15); // Thursday
    expect(ViewUnit.day.startOf(d), DateTime(2026, 8, 20));
    expect(ViewUnit.week.startOf(d), DateTime(2026, 8, 17));
    expect(ViewUnit.weeks3.startOf(d), DateTime(2026, 8, 17));
    expect(ViewUnit.month.startOf(d), DateTime(2026, 8, 1));
    expect(ViewUnit.months2.startOf(d), DateTime(2026, 7, 1));
    expect(ViewUnit.quarter.startOf(d), DateTime(2026, 7, 1));
    expect(ViewUnit.months6.startOf(d), DateTime(2026, 7, 1));
    expect(ViewUnit.year.startOf(d), DateTime(2026, 1, 1));
  });

  test('spans are whole calendar units', () {
    expect(ViewUnit.month.spanFrom(DateTime(2026, 2, 1)).days, 28);
    expect(ViewUnit.month.spanFrom(DateTime(2028, 2, 1)).days, 29);
    expect(ViewUnit.month.spanFrom(DateTime(2026, 1, 1)).days, 31);
    expect(ViewUnit.quarter.spanFrom(DateTime(2026, 1, 1)).days, 90);
    expect(ViewUnit.year.spanFrom(DateTime(2028, 1, 1)).days, 366);
    expect(ViewUnit.weeks2.spanFrom(DateTime(2026, 8, 17)).days, 14);
  });

  test('stepping across DST stays on midnight / Monday', () {
    // Sydney DST starts Sun 4 Oct 2026.
    final w = ViewUnit.week.step(DateTime(2026, 9, 28), 1);
    expect(w.start, DateTime(2026, 10, 5));
    expect(w.days, 7);
    final back = ViewUnit.week.step(DateTime(2026, 10, 5), -1);
    expect(back.start, DateTime(2026, 9, 28));
    final day = ViewUnit.day.step(DateTime(2026, 10, 4), 1);
    expect(day.start, DateTime(2026, 10, 5));
    // April (DST ends Sun 5 Apr 2026): month spans 30 days.
    expect(ViewUnit.month.step(DateTime(2026, 3, 1), 1).days, 30);
  });

  test('month / year stepping, incl. month end and year boundary', () {
    expect(
      ViewUnit.month.step(DateTime(2026, 1, 1), 1).start,
      DateTime(2026, 2, 1),
    );
    expect(
      ViewUnit.month.step(DateTime(2026, 12, 1), 1).start,
      DateTime(2027, 1, 1),
    );
    expect(
      ViewUnit.month.step(DateTime(2026, 1, 1), -1).start,
      DateTime(2025, 12, 1),
    );
    expect(
      ViewUnit.year.step(DateTime(2026, 1, 1), 1).start,
      DateTime(2027, 1, 1),
    );
    expect(
      ViewUnit.quarter.step(DateTime(2026, 10, 1), 1).start,
      DateTime(2027, 1, 1),
    );
  });

  test('unaligned view snaps: left to containing unit, right to next', () {
    final start = DateTime(2026, 1, 31); // mid-unit for month
    expect(ViewUnit.month.step(start, -1).start, DateTime(2026, 1, 1));
    expect(ViewUnit.month.step(start, 1).start, DateTime(2026, 2, 1));
    expect(ViewUnit.month.step(start, 1).days, 28);
    final frac = addDays(DateTime(2026, 8, 19), 0.4);
    expect(ViewUnit.week.step(frac, -1).start, DateTime(2026, 8, 17));
    expect(ViewUnit.week.step(frac, 1).start, DateTime(2026, 8, 24));
  });

  test('nearest unit for a free span', () {
    expect(ViewUnit.nearest(1), ViewUnit.day);
    expect(ViewUnit.nearest(8), ViewUnit.week);
    expect(ViewUnit.nearest(31), ViewUnit.month);
    expect(ViewUnit.nearest(70), ViewUnit.months2);
    expect(ViewUnit.nearest(100), ViewUnit.quarter);
    expect(ViewUnit.nearest(400), ViewUnit.year);
    expect(ViewUnit.nearest(5000), ViewUnit.year);
    expect(ViewUnit.nearest(0.5), ViewUnit.day);
  });
}
