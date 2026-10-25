import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEvent tx({
  RecurrenceMode mode = RecurrenceMode.every,
  int interval = 1,
  RecurrenceUnit unit = RecurrenceUnit.months,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
}) => BudgetEvent(
  id: 't',
  streamId: 'a',
  name: 'n',
  direction: EventDirection.debit,
  amount: Decimal.one,
  startDate: DateTime(2026, 1, 31),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.once ? null : interval,
  unit: mode == RecurrenceMode.once ? null : unit,
  endMode: end,
  endDate: endDate,
  occurrenceCount: count,
);

void main() {
  test('ordinal suffixes 1..31 (11-13 take th)', () {
    const want = {
      1: '1st',
      2: '2nd',
      3: '3rd',
      4: '4th',
      5: '5th',
      9: '9th',
      10: '10th',
      11: '11th',
      12: '12th',
      13: '13th',
      14: '14th',
      20: '20th',
      21: '21st',
      22: '22nd',
      23: '23rd',
      24: '24th',
      29: '29th',
      30: '30th',
      31: '31st',
    };
    for (var n = 1; n <= 31; n++) {
      final o = ordinal(n);
      expect(o, startsWith('$n'));
      if (want[n] != null) expect(o, want[n], reason: '$n');
      final teen = n >= 11 && n <= 13;
      final suffix = teen
          ? 'th'
          : switch (n % 10) {
              1 => 'st',
              2 => 'nd',
              3 => 'rd',
              _ => 'th',
            };
      expect(ordinalSuffix(n), suffix, reason: '$n');
    }
    expect(ordinal(111), '111th');
    expect(ordinal(101), '101st');
  });

  test('selected date: long weekday, ordinal day, long month; year only '
      'outside the current year', () {
    final now = DateTime(2026, 10, 20);
    expect(
      formatSelectedDate(DateTime(2026, 10, 14), now: now),
      'Wednesday 14th October',
    );
    expect(
      formatSelectedDate(DateTime(2026, 10, 1), now: now),
      'Thursday 1st October',
    );
    expect(
      formatSelectedDate(DateTime(2026, 10, 22), now: now),
      'Thursday 22nd October',
    );
    expect(
      formatSelectedDate(DateTime(2026, 10, 23), now: now),
      'Friday 23rd October',
    );
    expect(
      formatSelectedDate(DateTime(2026, 9, 11), now: now),
      'Friday 11th September',
    );
    expect(
      formatSelectedDate(DateTime(2027, 1, 1), now: now),
      'Friday 1st January 2027',
    );
    expect(
      formatSelectedDate(DateTime(2025, 12, 31), now: now),
      'Wednesday 31st December 2025',
    );
  });

  test('formats occurrence dates', () {
    expect(formatOccurrenceDate(DateTime(2026, 1, 12)), 'Mon 12 Jan 2026');
  });

  test('describes recurrence', () {
    expect(describeRecurrence(tx(mode: RecurrenceMode.once)), 'One-off');
    expect(describeRecurrence(tx()), 'Every month');
    expect(
      describeRecurrence(
        tx(
          interval: 2,
          unit: RecurrenceUnit.weeks,
          end: EndMode.untilDate,
          endDate: DateTime(2027, 6, 30),
        ),
      ),
      'Every 2 weeks, ends 30 Jun 2027',
    );
    expect(
      describeRecurrence(tx(end: EndMode.count, count: 12)),
      'Every month, 12 times',
    );
  });

  test('occurrence ordinal for counted schedules (month-end clamping)', () {
    final t = tx(end: EndMode.count, count: 4);
    expect(occurrenceOrdinal(t, DateTime(2026, 1, 31)), 'Occurrence 1 of 4');
    expect(occurrenceOrdinal(t, DateTime(2026, 4, 30)), isNotNull);
    expect(occurrenceOrdinal(t, DateTime(2026, 2, 15)), isNull);
    expect(occurrenceOrdinal(tx(), DateTime(2026, 1, 31)), isNull);
  });
}
