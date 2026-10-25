// Run under a DST zone to exercise the 23h/25h days, e.g.
//   TZ=Australia/Sydney flutter test test/timeline_dst_test.dart
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/zoom_level.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Spans both Australian (Apr/Oct) and northern (Mar/Oct-Nov) DST changes.
  final from = DateTime(2026, 1, 1);
  final to = DateTime(2027, 1, 1);

  test('day segments start at midnight and never repeat or skip a date', () {
    final days = daySegments(from, to);
    expect(days, hasLength(365));
    for (var i = 0; i < days.length; i++) {
      final d = days[i].start;
      expect(d, DateTime(2026, 1, 1 + i));
      expect(d.hour, 0, reason: '$d');
    }
  });

  test('week segments always start on Monday at midnight', () {
    for (final week in weekSegments(from, to)) {
      expect(week.start.weekday, DateTime.monday, reason: '${week.start}');
      expect(week.start.hour, 0, reason: '${week.start}');
    }
  });

  test('every calendar day is exactly one unit wide', () {
    for (var i = 0; i < 365; i++) {
      final d = DateTime(2026, 1, 1 + i);
      final next = DateTime(2026, 1, 2 + i);
      expect(dayCoord(next) - dayCoord(d), closeTo(1, 1e-9), reason: '$d');
    }
  });

  test('addDays round-trips through day coordinates across DST', () {
    final start = DateTime(2026, 3, 20, 6);
    for (var i = 0; i < 400; i++) {
      final moved = addDays(start, i.toDouble());
      expect(moved.hour, 6, reason: '$moved');
      expect(dateOnly(moved), DateTime(2026, 3, 20 + i));
    }
    expect(addDays(DateTime(2026, 4, 4), 1.5), DateTime(2026, 4, 5, 12));
  });

  test('dateToX / xToDate agree with calendar days', () {
    for (var i = 0; i < 365; i++) {
      final d = DateTime(2026, 1, 1 + i);
      expect(xToDate(dateToX(d)), d);
      expect(dateToX(DateTime(2026, 1, 2 + i)) - dateToX(d), 1);
    }
  });

  test('daily and weekly previews stay on the right date across DST', () {
    final weekly = BudgetEvent(
      id: 't',
      streamId: 'a',
      name: 'Groceries',
      direction: EventDirection.debit,
      amount: Decimal.one,
      startDate: DateTime(2026, 3, 2),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      enabled: true,
    );
    final dates = estimateOccurrenceDates(weekly, maxCount: 40);
    for (final d in dates) {
      expect(d.weekday, DateTime.monday, reason: '$d');
      expect(d.hour, 0, reason: '$d');
    }
  });
}
