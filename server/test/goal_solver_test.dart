import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/engine/goal_solver.dart';
import 'package:budget_server/engine/solver.dart' show SolverException;
import 'package:test/test.dart';

final _start = DateTime.utc(2026, 1, 1);

/// Flat 1000 baseline for [days] from 1 Jan 2026 (no other events),
/// optionally with a weekly −100 bill from 5 Jan.
GoalBaseline _baseline({int days = 800, bool bills = false}) {
  var b = 1000.0;
  final closes = <double>[];
  for (var i = 0; i < days; i++) {
    final d = _start.add(Duration(days: i));
    if (bills && d.weekday == DateTime.monday) b -= 100;
    closes.add(b);
  }
  return GoalBaseline(from: _start, opening: 1000, closes: closes);
}

GoalSolver _solver({bool bills = false, double threshold = 0}) => GoalSolver(
      baseline: _baseline(bills: bills),
      threshold: threshold,
      today: _start,
      horizonDays: 790,
    );

void main() {
  group('GoalSolver', () {
    test('missing knowns are reported (needs N of)', () {
      final r = _solver().solve(GoalRequest(solveFor: GoalVar.amount));
      expect(r.isComplete, isFalse);
      expect(r.needs, [GoalVar.targetBalance, GoalVar.endDate]);
      expect(r.toJson()['needsMore'], 2);
    });

    test('balance on a date with a weekly contribution', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 1, 29), // Thu 1, 8, 15, 22, 29 → 5 payments
        amount: 100,
      ));
      expect(r.endBalance, closeTo(1500, 1e-9));
      expect(r.values!['count'], 5);
    });

    test('amount per week to reach a target balance by a date', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.amount,
        startDate: _start,
        endDate: DateTime.utc(2026, 1, 29),
        targetBalance: 2000,
      ));
      expect(r.values!['amount'], '200.00');
      expect(r.endBalance, closeTo(2000, 1e-6));
    });

    test('amount streams for existing bills', () {
      final r = _solver(bills: true).solve(GoalRequest(
        solveFor: GoalVar.amount,
        startDate: _start,
        endDate: DateTime.utc(2026, 1, 29), // 4 Mondays of −100
        targetBalance: 2000,
      ));
      expect(r.values!['amount'], '280.00'); // (2000 − 600) / 5
      expect(r.baselineEndBalance, closeTo(600, 1e-9));
    });

    test('how long until the target saving \$C/week', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.endDate,
        startDate: _start,
        targetBalance: 1350,
        amount: 100,
      ));
      // 4th payment on 22 Jan reaches 1400.
      expect(r.values!['endDate'], '2026-01-22');
    });

    test('runway: floor mode end date is the last day above the target', () {
      final r = _solver(bills: true).solve(GoalRequest(
        solveFor: GoalVar.endDate,
        mode: GoalMode.floor,
        startDate: _start,
        targetBalance: 0,
      ));
      // 1000 − 100 each Monday: −100 on the 11th Monday (16 Mar).
      expect(r.values!['endDate'], '2026-03-15');
    });

    test('max one-off spend today and still have \$X on a date', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.oneOff,
        startDate: _start,
        endDate: DateTime.utc(2026, 3, 1),
        targetBalance: 400,
      ));
      expect(r.values!['oneOff'], '-600.00');
      expect(r.affordability!['affordable'], isTrue);
    });

    test('start balance needed to never drop below the alert', () {
      final r = _solver(bills: true).solve(GoalRequest(
        solveFor: GoalVar.startBalance,
        mode: GoalMode.floor,
        startDate: _start,
        endDate: DateTime.utc(2026, 1, 31), // 4 bills
        targetBalance: 0,
      ));
      expect(r.values!['startBalance'], '400.00');
    });

    test('count of payments needed', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.count,
        startDate: _start,
        endDate: DateTime.utc(2026, 6, 1),
        targetBalance: 1450,
        amount: 100,
      ));
      expect(r.values!['count'], 5);
    });

    test('least frequent spacing that still reaches the target', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.interval,
        startDate: _start,
        endDate: DateTime.utc(2026, 2, 26), // 9 weekly Thursdays
        targetBalance: 1500,
        amount: 100,
      ));
      // Every 2 weeks → 5 payments (1, 15, 29 Jan, 12, 26 Feb).
      expect(r.values!['interval'], 2);
    });

    test('latest start date that still reaches the target', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.startDate,
        endDate: DateTime.utc(2026, 1, 29),
        targetBalance: 1300,
        amount: 100,
      ));
      // Start 15 Jan: 15, 22, 29 → 1300.
      expect(r.values!['startDate'], '2026-01-15');
    });

    test('affordability of a purchase that breaks the alert line', () {
      final r = _solver(bills: true, threshold: 200).solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 2, 28),
        oneOff: -500,
      ));
      final a = r.affordability!;
      expect(a['affordable'], isFalse);
      // 500 after purchase; bills from 5 Jan: 400, 300, 200 (19 Jan, on the
      // line: still safe and not an alert), 100 (26 Jan) < 200.
      expect(a['safeUntil'], '2026-01-25');
      expect(r.alertDate, DateTime.utc(2026, 1, 26));
    });

    test('a balance equal to the alert line is no alert', () {
      // Flat 1000 with the threshold at 1000: touching, never below.
      final r = _solver(threshold: 1000).solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 3, 1),
        oneOff: -0.0001,
      ));
      expect(r.alertDate, isNull);
      expect(r.affordability!['affordable'], isTrue);
      final z = GoalSolver(
        baseline: GoalBaseline(
            from: _start, opening: 0, closes: List.filled(800, 0.0)),
        threshold: 0,
        today: _start,
        horizonDays: 790,
      ).solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 3, 1),
      ));
      expect(z.alertDate, isNull, reason: '0 balance, 0 threshold');
    });

    test('interest compounds daily on the whole balance', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2027, 1, 1),
        rate: 10,
      ));
      // 366 days of r/365 daily compounding on 1000.
      final expected = 1000 * _pow(1 + 0.10 / 365, 366);
      expect(r.endBalance, closeTo(expected, 0.5));
    });

    test('rate is solved numerically (round trip)', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.rate,
        startDate: _start,
        endDate: DateTime.utc(2027, 1, 1),
        targetBalance: 1105.3,
      ));
      expect((r.values!['rate'] as num).toDouble(), closeTo(10, 0.05));
    });

    test('an affordable purchase reports the worst point', () {
      final r = _solver(threshold: 200).solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 3, 1),
        oneOff: -500,
      ));
      final a = r.affordability!;
      expect(a['affordable'], isTrue);
      expect(a['safeUntil'], '2026-03-01');
    });

    test('unreachable targets explain why', () {
      expect(
        () => _solver().solve(GoalRequest(
          solveFor: GoalVar.endDate,
          startDate: _start,
          targetBalance: 5000,
        )),
        throwsA(isA<SolverException>()),
      );
    });

    test('ghost points are change points from the day before the start', () {
      final r = _solver().solve(GoalRequest(
        solveFor: GoalVar.targetBalance,
        startDate: _start,
        endDate: DateTime.utc(2026, 1, 10),
        amount: 50,
        unit: RecurrenceUnit.weeks,
      ));
      final dates = [for (final p in r.points) p.date.day];
      expect(dates.first, 31); // 31 Dec opening
      expect(dates, containsAllInOrder([1, 8, 10]));
    });
  });
}

double _pow(double b, int n) {
  var r = 1.0;
  for (var i = 0; i < n; i++) {
    r *= b;
  }
  return r;
}
