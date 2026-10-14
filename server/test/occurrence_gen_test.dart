import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

Transaction _transaction({
  String id = 's1',
  RecurrenceMode mode = RecurrenceMode.every,
  int? interval = 1,
  RecurrenceUnit? unit = RecurrenceUnit.months,
  EndMode endMode = EndMode.never,
  DateTime? endDate,
  int? occurrenceCount,
  DateTime? start,
  bool enabled = true,
}) {
  return Transaction(
    id: id,
    accountId: 'a1',
    name: 'Rent',
    direction: Direction.debit,
    amount: Decimal.parse('1000'),
    startDate: start ?? DateTime.utc(2024, 1, 31),
    recurrenceMode: mode,
    interval: mode == RecurrenceMode.once ? null : interval,
    unit: mode == RecurrenceMode.once ? null : unit,
    endMode: endMode,
    endDate: endDate,
    occurrenceCount: occurrenceCount,
    enabled: enabled,
    createdAt: DateTime.utc(2024, 1, 1),
  );
}

void main() {
  group('OccurrenceGenerator', () {
    test('once transaction yields single date in window', () {
      final s = _transaction(mode: RecurrenceMode.once, start: DateTime.utc(2024, 3, 5));
      final dates = OccurrenceGenerator.datesForTransaction(
        s,
        DateTime.utc(2024, 3, 1),
        DateTime.utc(2024, 3, 31),
      );
      expect(dates, [DateTime.utc(2024, 3, 5)]);
    });

    test('monthly transaction clamps and stays inside window', () {
      final s = _transaction();
      final dates = OccurrenceGenerator.datesForTransaction(
        s,
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 4, 30),
      );
      expect(dates, [
        DateTime.utc(2024, 1, 31),
        DateTime.utc(2024, 2, 29),
        DateTime.utc(2024, 3, 31),
        DateTime.utc(2024, 4, 30),
      ]);
    });

    test('count end rule limits occurrences', () {
      final s = _transaction(
        endMode: EndMode.count,
        occurrenceCount: 2,
        unit: RecurrenceUnit.weeks,
        start: DateTime.utc(2024, 1, 1),
      );
      final dates = OccurrenceGenerator.datesForTransaction(
        s,
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 12, 31),
      );
      expect(dates, [
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 1, 8),
      ]);
    });

    test('until_date inclusive', () {
      final s = _transaction(
        endMode: EndMode.untilDate,
        endDate: DateTime.utc(2024, 2, 29),
        start: DateTime.utc(2024, 1, 31),
      );
      final dates = OccurrenceGenerator.datesForTransaction(
        s,
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 12, 31),
      );
      expect(dates, [
        DateTime.utc(2024, 1, 31),
        DateTime.utc(2024, 2, 29),
      ]);
    });

    test('disabled transactions contribute nothing', () {
      final s = _transaction(enabled: false);
      final occ = OccurrenceGenerator.generate(
        transactions: [s],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 3, 1),
      );
      expect(occ, isEmpty);
    });

    test('skipped flag does not remove occurrence from list', () {
      final s = _transaction(mode: RecurrenceMode.once, start: DateTime.utc(2024, 1, 10));
      final occ = OccurrenceGenerator.generate(
        transactions: [s],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 31),
        skipped: {
          's1': {DateTime.utc(2024, 1, 10)},
        },
      );
      expect(occ, hasLength(1));
      expect(occ.first.skipped, isTrue);
      expect(occ.first.signedDelta, Decimal.parse('-1000'));
    });
  });
}
