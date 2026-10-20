// Run under a DST zone too: TZ=Australia/Sydney flutter test
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/fit_ranges.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction tx(
  DateTime start, {
  RecurrenceMode mode = RecurrenceMode.every,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
  bool enabled = true,
}) => Transaction(
  id: 'x',
  poolId: 'a',
  name: 'n',
  direction: TransactionDirection.values.first,
  amount: Decimal.one,
  startDate: start,
  recurrenceMode: mode,
  interval: 1,
  unit: RecurrenceUnit.months,
  endMode: end,
  endDate: endDate,
  occurrenceCount: count,
  enabled: enabled,
);

void main() {
  test('week is Monday-start and 7 calendar days, across DST', () {
    // Sydney DST starts Sun 4 Oct 2026; Europe/US ends late Oct/early Nov.
    for (
      var d = DateTime(2026, 1, 1);
      d.isBefore(DateTime(2027, 1, 1));
      d = addCalendarDays(d, 1)
    ) {
      final w = weekContaining(addDays(d, 0.6));
      expect(w.start.weekday, DateTime.monday);
      expect(w.start.hour, 0);
      expect(w.days, 7);
      expect(!w.start.isAfter(d), isTrue);
      expect(dateOnlyEq(addCalendarDays(w.start, 7), d), isFalse);
      expect(calendarDaysBetween(w.start, d), inInclusiveRange(0, 6));
      expect(dayCoord(w.end), dayCoord(addCalendarDays(w.start, 7)));
    }
    expect(
      weekContaining(DateTime(2026, 10, 4, 12)).start,
      DateTime(2026, 9, 28),
    );
    expect(weekContaining(DateTime(2026, 10, 5)).start, DateTime(2026, 10, 5));
  });

  test('month covers the calendar month incl. month ends and leap Feb', () {
    expect(
      monthContaining(DateTime(2026, 1, 31, 23)),
      TimeSpan(DateTime(2026, 1, 1), 31),
    );
    expect(
      monthContaining(DateTime(2026, 2, 15)),
      TimeSpan(DateTime(2026, 2, 1), 28),
    );
    expect(
      monthContaining(DateTime(2028, 2, 29)),
      TimeSpan(DateTime(2028, 2, 1), 29),
    );
    expect(
      monthContaining(DateTime(2026, 4, 30)),
      TimeSpan(DateTime(2026, 4, 1), 30),
    );
    // DST months (Apr/Oct in Sydney, Mar/Nov elsewhere).
    expect(
      monthContaining(DateTime(2026, 10, 4, 12)),
      TimeSpan(DateTime(2026, 10, 1), 31),
    );
    expect(
      monthContaining(DateTime(2026, 12, 31)),
      TimeSpan(DateTime(2026, 12, 1), 31),
    );
    for (var m = 1; m <= 12; m++) {
      final s = monthContaining(DateTime(2026, m, 10));
      expect(dayCoord(s.end), dayCoord(DateTime(2026, m + 1)));
    }
  });

  test('pool data range uses seed, finite ends and open-ended horizon', () {
    final today = DateTime(2026, 10, 15);
    final seed = DateTime(2026, 3, 1);
    var r = poolDataRange(seedDate: seed, transactions: [], today: today);
    expect((r.first, r.last), (seed, seed));
    r = poolDataRange(
      seedDate: seed,
      today: today,
      transactions: [
        tx(DateTime(2026, 2, 10), mode: RecurrenceMode.once),
        tx(
          DateTime(2026, 4, 1),
          end: EndMode.untilDate,
          endDate: DateTime(2027, 6, 30),
        ),
        tx(DateTime(2026, 1, 31), end: EndMode.count, count: 3),
        tx(DateTime(2020, 1, 1), enabled: false),
      ],
    );
    expect(r.first, DateTime(2026, 1, 31));
    expect(r.last, DateTime(2027, 6, 30));
    r = poolDataRange(
      seedDate: seed,
      today: today,
      transactions: [tx(DateTime(2026, 4, 1))],
    );
    expect(r.last, DateTime(2027, 10, 15));
  });

  test('padded time span pads and respects zoom limits', () {
    final s = dataTimeSpan(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
    // First day exactly at the left edge, last day fully visible.
    expect(s.start, DateTime(2026, 1, 1));
    expect(s.days, 365);
    expect(dateOnlyEq(s.end, DateTime(2027, 1, 1)), isTrue);
    final one = dataTimeSpan(DateTime(2026, 5, 5), DateTime(2026, 5, 5));
    expect(one.days, minVisibleDays);
    expect(one.start, DateTime(2026, 5, 5));
    final huge = dataTimeSpan(DateTime(1990, 1, 1), DateTime(2030, 1, 1));
    expect(huge.days, maxVisibleDays);
    expect(huge.start, DateTime(1990, 1, 1));
  });

  test('week / month fits start exactly at the unit start', () {
    final w = weekContaining(DateTime(2025, 11, 27, 15));
    expect(w.start, DateTime(2025, 11, 24)); // Monday
    expect(w.days, 7);
    expect(lastVisibleDay(w.start, w.days), DateTime(2025, 11, 30));
    final m = monthContaining(DateTime(2025, 11, 15));
    expect(m.start, DateTime(2025, 11, 1));
    expect(lastVisibleDay(m.start, m.days), DateTime(2025, 11, 30));
    // Across the April DST change (Sydney) the span is still whole days.
    final a = monthContaining(DateTime(2026, 4, 10));
    expect(a.days, 30);
    expect(lastVisibleDay(a.start, a.days), DateTime(2026, 4, 30));
  });
}

bool dateOnlyEq(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
