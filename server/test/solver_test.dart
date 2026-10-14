import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/engine/solver.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

void main() {
  group('TransactionSolver', () {
    test('start, total, weekly alone asks for one of amount/count/end', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2026, 1, 5),
          interval: 1,
          targetTotal: Decimal.parse('1000'),
        ),
      );
      expect(result.isComplete, isFalse);
      expect(result.needsMore, 1);
      expect(
        result.needsOneOf,
        [SolveVar.endDate, SolveVar.amount, SolveVar.count],
      );
    });

    test('start, total, weekly, amount → count and end date', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2026, 1, 5),
          interval: 1,
          targetTotal: Decimal.parse('1000'),
          amount: Decimal.parse('100'),
        ),
      );
      expect(result.isComplete, isTrue);
      expect(result.solved, {SolveVar.count, SolveVar.endDate});
      expect(result.values.count, 10);
      expect(result.values.endDate, DateTime.utc(2026, 3, 9));
      expect(result.transaction!.endMode, EndMode.count);
      expect(result.transaction!.occurrenceCount, 10);
      expect(result.previewOccurrences, hasLength(10));
    });

    test('start, total, weekly, end date → count and amount', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2026, 1, 5),
          interval: 1,
          targetTotal: Decimal.parse('1000'),
          endDate: DateTime.utc(2026, 1, 26),
        ),
      );
      expect(result.solved, {SolveVar.count, SolveVar.amount});
      expect(result.values.count, 4);
      expect(result.values.amount, Decimal.parse('250'));
      expect(result.transaction!.endMode, EndMode.untilDate);
      expect(result.transaction!.endDate, DateTime.utc(2026, 1, 26));
    });

    test('start, total, weekly, count → amount and end date', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2024, 1, 1),
          interval: 1,
          occurrenceCount: 4,
          targetTotal: Decimal.parse('100'),
        ),
      );
      expect(result.values.amount, Decimal.parse('25'));
      expect(result.values.endDate, DateTime.utc(2024, 1, 22));
    });

    test('amount, count, start → total and end date', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.credit,
          unit: RecurrenceUnit.months,
          startDate: DateTime.utc(2024, 1, 15),
          interval: 1,
          amount: Decimal.parse('50'),
          occurrenceCount: 3,
        ),
      );
      expect(result.solved, {SolveVar.total, SolveVar.endDate});
      expect(result.values.total, Decimal.parse('150'));
      expect(result.values.endDate, DateTime.utc(2024, 3, 15));
    });

    test('end date, count, monthly, amount → start date', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.months,
          endDate: DateTime.utc(2024, 6, 1),
          interval: 1,
          occurrenceCount: 6,
          amount: Decimal.parse('10'),
        ),
      );
      expect(result.solved, contains(SolveVar.startDate));
      expect(result.values.startDate, DateTime.utc(2024, 1, 1));
      expect(result.previewOccurrences, hasLength(6));
    });

    test('start, end, amount, total → frequency interval', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.credit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2024, 1, 1),
          endDate: DateTime.utc(2024, 1, 29),
          amount: Decimal.parse('10'),
          targetTotal: Decimal.parse('30'),
        ),
      );
      // Jan 1, 15, 29 → every 2 weeks.
      expect(result.values.interval, 2);
      expect(result.values.count, 3);
    });

    test('frequency with no exact interval explains the closest options', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.credit,
            unit: RecurrenceUnit.weeks,
            startDate: DateTime.utc(2024, 1, 1),
            endDate: DateTime.utc(2024, 1, 29),
            occurrenceCount: 4,
            amount: Decimal.parse('10'),
          ),
        ),
        throwsA(
          isA<SolverException>().having(
            (e) => e.message,
            'message',
            contains('every 1 weeks gives 5'),
          ),
        ),
      );
    });

    test('single occurrence becomes a once transaction', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2024, 1, 1),
          interval: 1,
          amount: Decimal.parse('100'),
          targetTotal: Decimal.parse('100'),
        ),
      );
      expect(result.transaction!.recurrenceMode, RecurrenceMode.once);
      expect(result.values.endDate, DateTime.utc(2024, 1, 1));
    });

    test('rounding atLeast for count', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.days,
          startDate: DateTime.utc(2024, 1, 1),
          interval: 1,
          amount: Decimal.parse('30'),
          targetTotal: Decimal.parse('100'),
          rounding: RoundingMode.atLeast,
        ),
      );
      // 100/30 = 3.333 → ceil = 4
      expect(result.values.count, 4);
      expect(result.toJson()['values'], containsPair('actualTotal', '120'));
    });

    test('rounding amount to cents', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.months,
          startDate: DateTime.utc(2024, 1, 1),
          interval: 1,
          occurrenceCount: 3,
          targetTotal: Decimal.parse('100'),
          rounding: RoundingMode.atLeast,
        ),
      );
      expect(result.values.amount, Decimal.parse('33.34'));
    });

    test('consistent over-specified input is accepted', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2026, 1, 5),
          interval: 1,
          amount: Decimal.parse('100'),
          occurrenceCount: 10,
          targetTotal: Decimal.parse('1000'),
        ),
      );
      expect(result.isComplete, isTrue);
    });

    test('conflicting total is rejected', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.debit,
            unit: RecurrenceUnit.weeks,
            startDate: DateTime.utc(2026, 1, 5),
            interval: 1,
            amount: Decimal.parse('300'),
            occurrenceCount: 4,
            targetTotal: Decimal.parse('1000'),
          ),
        ),
        throwsA(isA<SolverException>()),
      );
    });

    test('conflicting schedule is rejected', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.debit,
            unit: RecurrenceUnit.weeks,
            startDate: DateTime.utc(2026, 1, 5),
            endDate: DateTime.utc(2026, 1, 26),
            interval: 1,
            occurrenceCount: 10,
          ),
        ),
        throwsA(isA<SolverException>()),
      );
    });

    test('only start and frequency needs two more values', () {
      final result = TransactionSolver.solve(
        SolveRequest(
          direction: Direction.debit,
          unit: RecurrenceUnit.weeks,
          startDate: DateTime.utc(2026, 1, 5),
          interval: 1,
        ),
      );
      expect(result.needsMore, 2);
    });

    test('rejects amount = 0', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.credit,
            unit: RecurrenceUnit.days,
            startDate: DateTime.utc(2024, 1, 1),
            amount: Decimal.zero,
            targetTotal: Decimal.parse('100'),
            interval: 1,
          ),
        ),
        throwsA(isA<SolverException>()),
      );
    });

    test('rejects end before start', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.credit,
            unit: RecurrenceUnit.days,
            startDate: DateTime.utc(2024, 2, 1),
            endDate: DateTime.utc(2024, 1, 1),
            targetTotal: Decimal.parse('100'),
            interval: 1,
          ),
        ),
        throwsA(isA<SolverException>()),
      );
    });

    test('rejects interval < 1', () {
      expect(
        () => TransactionSolver.solve(
          SolveRequest(
            direction: Direction.credit,
            unit: RecurrenceUnit.days,
            startDate: DateTime.utc(2024, 1, 1),
            amount: Decimal.parse('10'),
            targetTotal: Decimal.parse('100'),
            interval: 0,
          ),
        ),
        throwsA(isA<SolverException>()),
      );
    });
  });
}
