import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

BudgetEvent _credit({
  required String id,
  required Decimal amount,
  required DateTime date,
  DateTime? createdAt,
}) {
  return BudgetEvent(
    id: id,
    streamId: 'a1',
    name: id,
    direction: Direction.credit,
    amount: amount,
    startDate: date,
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
    enabled: true,
    createdAt: createdAt ?? DateTime.utc(2024, 1, 1),
  );
}

BudgetEvent _debit({
  required String id,
  required Decimal amount,
  required DateTime date,
  DateTime? createdAt,
}) {
  return BudgetEvent(
    id: id,
    streamId: 'a1',
    name: id,
    direction: Direction.debit,
    amount: amount,
    startDate: date,
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
    enabled: true,
    createdAt: createdAt ?? DateTime.utc(2024, 1, 1),
  );
}

void main() {
  group('BalanceEngine', () {
    test('opening on seedDate equals seedBalance before occurrences', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.parse('100'),
        seedDate: DateTime.utc(2024, 1, 1),
        events: [
          _credit(
            id: 'c1',
            amount: Decimal.parse('50'),
            date: DateTime.utc(2024, 1, 1),
          ),
        ],
        eventOrder: ['c1'],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 1),
      );
      expect(series.points, hasLength(1));
      expect(series.points.first.closingBalance, Decimal.parse('150'));
    });

    test('window after the seed still counts earlier occurrences', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.parse('100'),
        seedDate: DateTime.utc(2024, 1, 1),
        events: [
          _credit(
            id: 'c1',
            amount: Decimal.parse('50'),
            date: DateTime.utc(2024, 1, 5),
          ),
        ],
        eventOrder: ['c1'],
        from: DateTime.utc(2024, 2, 1),
        to: DateTime.utc(2024, 2, 1),
      );
      expect(series.points.single.closingBalance, Decimal.parse('150'));
      expect(series.occurrences, isEmpty);
    });

    test('does not emit points before seedDate', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.parse('10'),
        seedDate: DateTime.utc(2024, 1, 10),
        events: const [],
        eventOrder: const [],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 12),
      );
      expect(series.points.first.date, DateTime.utc(2024, 1, 10));
      expect(series.points.last.date, DateTime.utc(2024, 1, 12));
      expect(
          series.points.every((p) => p.closingBalance == Decimal.parse('10')),
          isTrue);
    });

    test('same-day order follows eventOrder', () {
      final a = _credit(
        id: 'a',
        amount: Decimal.parse('100'),
        date: DateTime.utc(2024, 1, 1),
        createdAt: DateTime.utc(2024, 1, 1),
      );
      final b = _debit(
        id: 'b',
        amount: Decimal.parse('30'),
        date: DateTime.utc(2024, 1, 1),
        createdAt: DateTime.utc(2024, 1, 2),
      );

      final series = BalanceEngine.compute(
        seedBalance: Decimal.zero,
        seedDate: DateTime.utc(2024, 1, 1),
        events: [a, b],
        eventOrder: ['b', 'a'],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 1),
      );

      // Order does not change commutative sum, but occurrences list is ordered.
      expect(series.occurrences.map((o) => o.eventId).toList(), ['b', 'a']);
      expect(series.points.first.closingBalance, Decimal.parse('70'));
    });

    test('skipped occurrence is excluded from balance', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.parse('100'),
        seedDate: DateTime.utc(2024, 1, 1),
        events: [
          _debit(
            id: 'rent',
            amount: Decimal.parse('40'),
            date: DateTime.utc(2024, 1, 2),
          ),
        ],
        eventOrder: ['rent'],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 2),
        skipped: {
          'rent': {DateTime.utc(2024, 1, 2)},
        },
      );
      expect(series.points.last.closingBalance, Decimal.parse('100'));
      expect(series.occurrences.single.skipped, isTrue);
    });

    test('carries balance across days', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.parse('0'),
        seedDate: DateTime.utc(2024, 1, 1),
        events: [
          _credit(
            id: 'pay',
            amount: Decimal.parse('10'),
            date: DateTime.utc(2024, 1, 1),
          ),
          _debit(
            id: 'coffee',
            amount: Decimal.parse('3'),
            date: DateTime.utc(2024, 1, 3),
          ),
        ],
        eventOrder: ['pay', 'coffee'],
        from: DateTime.utc(2024, 1, 1),
        to: DateTime.utc(2024, 1, 3),
      );
      expect(
        series.points.map((p) => p.closingBalance.toString()).toList(),
        ['10', '10', '7'],
      );
    });
  });
}
