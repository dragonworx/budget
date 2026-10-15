import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

Transaction tx({
  RecurrenceMode mode = RecurrenceMode.every,
  int interval = 1,
  RecurrenceUnit unit = RecurrenceUnit.months,
  EndMode end = EndMode.never,
  DateTime? endDate,
  int? count,
}) => Transaction(
  id: 't',
  accountId: 'a',
  name: 'n',
  direction: TransactionDirection.debit,
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
