import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/engine/calendar_math.dart';
import 'package:test/test.dart';

void main() {
  group('CalendarMath', () {
    test('adds days and weeks as fixed offsets', () {
      final start = DateTime.utc(2024, 1, 15);
      expect(
        CalendarMath.add(start, 3, RecurrenceUnit.days),
        DateTime.utc(2024, 1, 18),
      );
      expect(
        CalendarMath.add(start, 2, RecurrenceUnit.weeks),
        DateTime.utc(2024, 1, 29),
      );
    });

    test('clamps month end Jan 31 + 1 month → Feb 29 in leap year', () {
      final start = DateTime.utc(2024, 1, 31);
      expect(
        CalendarMath.add(start, 1, RecurrenceUnit.months),
        DateTime.utc(2024, 2, 29),
      );
    });

    test('clamps month end Jan 31 + 1 month → Feb 28 in non-leap year', () {
      final start = DateTime.utc(2023, 1, 31);
      expect(
        CalendarMath.add(start, 1, RecurrenceUnit.months),
        DateTime.utc(2023, 2, 28),
      );
    });

    test('Feb 29 + 1 year → Feb 28 in non-leap year', () {
      final start = DateTime.utc(2024, 2, 29);
      expect(
        CalendarMath.add(start, 1, RecurrenceUnit.years),
        DateTime.utc(2025, 2, 28),
      );
    });

    test('rejects interval < 1', () {
      expect(
        () =>
            CalendarMath.add(DateTime.utc(2024, 1, 1), 0, RecurrenceUnit.days),
        throwsArgumentError,
      );
    });
  });
}
