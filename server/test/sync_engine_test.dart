// Sync events in the balance engine and the loan walk (spec 015): the pin
// after the day's other moves, the winner by rank, drift, before-seed and
// disabled / hidden syncs, carry-in, the loan's pre-pin accrual and
// pinned payoff, offsets reading a synced close, transfers not propagated.
import 'package:budget_loan/budget_loan.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:budget_server/engine/loan_walk.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:budget_server/engine/stream_group.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);
Decimal dec(String v) => Decimal.parse(v);

BudgetEvent ev(String id, Direction dir, String amount, DateTime start,
        {RecurrenceUnit? unit, DateTime? created}) =>
    BudgetEvent(
      id: id,
      streamId: 's',
      name: id,
      direction: dir,
      amount: dec(amount),
      startDate: start,
      recurrenceMode: unit == null ? RecurrenceMode.once : RecurrenceMode.every,
      interval: unit == null ? null : 1,
      unit: unit,
      endMode: EndMode.never,
      enabled: true,
      createdAt: created ?? DateTime.utc(2021),
    );

BudgetEvent sync(String id, String balance, DateTime day,
        {DateTime? created, bool enabled = true, bool hidden = false}) =>
    BudgetEvent(
      id: id,
      streamId: 's',
      name: 'Sync',
      direction: Direction.credit,
      amount: dec(balance),
      startDate: day,
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
      enabled: enabled,
      categoryHidden: hidden,
      createdAt: created ?? DateTime.utc(2022),
      kind: EventKind.sync,
    );

BalanceSeries run(List<BudgetEvent> events,
        {List<String> order = const [],
        String seed = '100',
        DateTime? seedDate,
        DateTime? from,
        DateTime? to}) =>
    BalanceEngine.compute(
      seedBalance: dec(seed),
      seedDate: seedDate ?? d(2027, 1, 1),
      events: events,
      eventOrder: order,
      from: from ?? seedDate ?? d(2027, 1, 1),
      to: to ?? d(2027, 1, 31),
    );

String close(BalanceSeries s, DateTime day) =>
    s.points.firstWhere((p) => p.date == day).closingBalance.toStringAsFixed(2);

final weekly =
    ev('wk', Direction.credit, '10', d(2027, 1, 1), unit: RecurrenceUnit.weeks);

void main() {
  group('standard stream', () {
    test('a sync mid-series pins that day; later moves build on it', () {
      final s = run([weekly, sync('s1', '500', d(2027, 1, 10))]);
      // Jan 1, 8: +10 each -> 120 on Jan 9, pinned to 500 on Jan 10.
      expect(close(s, d(2027, 1, 9)), '120.00');
      expect(close(s, d(2027, 1, 10)), '500.00');
      expect(close(s, d(2027, 1, 15)), '510.00');
      expect(s.syncs.single.toJson(), {
        'eventId': 's1',
        'date': '2027-01-10',
        'balance': '500',
        'calculated': '120',
        'drift': '380',
        'superseded': false,
        'beforeSeed': false,
      });
      final o = s.occurrences.firstWhere((o) => o.component == 'sync');
      expect(o.toJson(), {
        'eventId': 's1',
        'date': '2027-01-10',
        'signedDelta': '380',
        'skipped': false,
        'component': 'sync',
        'syncBalance': '500',
        'calculated': '120',
      });
    });

    test('the pin comes after same-day moves, whatever their rank', () {
      final s = run([
        sync('s1', '1000', d(2027, 1, 5)),
        ev('in', Direction.credit, '20', d(2027, 1, 5)),
        ev('out', Direction.debit, '30', d(2027, 1, 5)),
      ], order: [
        's1',
        'in',
        'out'
      ]);
      expect(close(s, d(2027, 1, 5)), '1000.00');
      expect(s.syncs.single.calculated, dec('90'));
      // The sync occurrence follows the day's others.
      expect([
        for (final o in s.occurrences)
          if (o.date == d(2027, 1, 5)) o.eventId
      ], [
        'in',
        'out',
        's1'
      ]);
    });

    test('two syncs on one day: the later-ranked wins, the other superseded',
        () {
      final a = sync('a', '200', d(2027, 1, 3), created: DateTime.utc(2023));
      final b = sync('b', '300', d(2027, 1, 3), created: DateTime.utc(2022));
      var s = run([a, b], order: ['a', 'b']);
      expect(close(s, d(2027, 1, 3)), '300.00');
      expect([for (final r in s.syncs) (r.eventId, r.superseded)],
          [('a', true), ('b', false)]);
      // The superseded occurrence moves nothing.
      expect(
          s.occurrences.firstWhere((o) => o.eventId == 'a').toJson()
            ..remove('date'),
          {
            'eventId': 'a',
            'signedDelta': '0',
            'skipped': false,
            'component': 'sync',
            'syncBalance': '200',
            'calculated': '100',
            'superseded': true,
          });
      s = run([a, b], order: ['b', 'a']);
      expect(close(s, d(2027, 1, 3)), '200.00');
      // No order: creation order (b first, so a wins).
      s = run([a, b]);
      expect(close(s, d(2027, 1, 3)), '200.00');
    });

    test('zero, negative and seed-day syncs', () {
      expect(
          close(run([sync('z', '0', d(2027, 1, 2))]), d(2027, 1, 2)), '0.00');
      final neg = run([sync('n', '-1234.56', d(2027, 1, 2))]);
      expect(close(neg, d(2027, 1, 2)), '-1234.56');
      expect(neg.syncs.single.drift, dec('-1334.56'));
      // On the seed date: after the seed and that day's moves.
      final seedDay = run([weekly, sync('sd', '42', d(2027, 1, 1))]);
      expect(close(seedDay, d(2027, 1, 1)), '42.00');
      expect(seedDay.syncs.single.calculated, dec('110'));
    });

    test('a before-seed sync is ignored and flagged', () {
      final s = run([weekly, sync('old', '999', d(2026, 12, 1))]);
      expect(close(s, d(2027, 1, 1)), '110.00');
      expect(s.syncs.single.toJson(), {
        'eventId': 'old',
        'date': '2026-12-01',
        'balance': '999',
        'calculated': null,
        'drift': null,
        'superseded': false,
        'beforeSeed': true,
      });
      expect(s.occurrences.any((o) => o.component == 'sync'), isFalse);
    });

    test('a sync before the window still sets the carry-in', () {
      final s =
          run([weekly, sync('s1', '500', d(2027, 1, 3))], from: d(2027, 1, 20));
      // 500 on Jan 3, then +10 on Jan 8 and 15.
      expect(close(s, d(2027, 1, 20)), '520.00');
      // Listed (the walk computed it), but no occurrence in the window.
      expect(s.syncs.single.eventId, 's1');
      expect(s.occurrences.any((o) => o.component == 'sync'), isFalse);
    });

    test('a future sync applies on its day', () {
      final s =
          run([weekly, sync('f', '-5', d(2040, 6, 1))], to: d(2040, 6, 2));
      expect(close(s, d(2040, 6, 1)), '-5.00');
      expect(close(s, d(2040, 6, 2)), '-5.00');
    });

    test('a disabled sync or a hidden Sync category has no effect', () {
      final plain = run([weekly]);
      for (final e in [
        sync('x', '1', d(2027, 1, 5), enabled: false),
        sync('x', '1', d(2027, 1, 5), hidden: true),
      ]) {
        final s = run([weekly, e]);
        expect([for (final p in s.points) p.toJson()],
            [for (final p in plain.points) p.toJson()]);
        expect(s.syncs, isEmpty);
      }
    });

    test('drift sign: below the calculated close is negative', () {
      final s = run([sync('lo', '90', d(2027, 1, 2))]);
      expect(s.syncs.single.drift, dec('-10'));
      final hi = run([sync('hi', '112.34', d(2027, 1, 2))]);
      expect(hi.syncs.single.drift, dec('12.34'));
    });

    test('the occurrence generator never expands a sync', () {
      expect(
          OccurrenceGenerator.generate(
              events: [sync('s1', '5', d(2027, 1, 2))],
              from: d(2027, 1, 1),
              to: d(2027, 1, 31)),
          isEmpty);
    });

    test('no syncs: no records, the same series', () {
      final s = run([weekly]);
      expect(s.syncs, isEmpty);
      expect(close(s, d(2027, 1, 31)), '150.00');
    });
  });

  group('loan stream', () {
    final s = d(2027, 1, 1);
    LoanTerms terms(String rate, {String interest = 'reducing'}) =>
        LoanTerms.fromJson({
          'v': 1,
          'mode': 'simple',
          'interestType': interest,
          'termMonths': 12,
          'repaymentFrequency': 'monthly',
          if (interest != 'flat') ...{
            'chargeDay': 'monthEnd',
            'dayCount': '365',
          },
          'ratePeriods': [
            {'from': '2027-01-01', 'ratePct': rate},
          ],
        }).withDefaults(s);
    BudgetEvent loan({String interest = 'reducing'}) => BudgetEvent(
          id: 'loan',
          streamId: 's',
          name: 'Loan',
          direction: Direction.debit,
          amount: dec('1000'),
          startDate: s,
          recurrenceMode: RecurrenceMode.once,
          endMode: EndMode.never,
          enabled: true,
          createdAt: DateTime.utc(2020),
          kind: EventKind.loan,
          loan: terms('3.65', interest: interest),
        );
    LoanWalkResult walk(List<BudgetEvent> events, DateTime until) =>
        LoanWalk.compute(
          seedBalance: Decimal.zero,
          seedDate: s,
          events: events,
          eventOrder: const [],
          from: s,
          to: until,
          loan: LoanWalk.activeLoan(events)!,
        );
    String charge(LoanWalkResult r, DateTime day) => r.charges
        .where((c) => c.date == day)
        .fold(Decimal.zero, (a, c) => a + c.amount)
        .toStringAsFixed(2);

    test('accrual: pre-pin owed on the sync day, pinned owed after', () {
      final base = walk([loan()], d(2027, 1, 31));
      final r =
          walk([loan(), sync('s1', '-500', d(2027, 1, 15))], d(2027, 1, 31));
      // 3.65% / 365 = 0.01% a day. Jan 16–31 (16 days) accrue on 500
      // instead of 1000: 16 × 0.05 = 0.80 less.
      expect(charge(base, d(2027, 1, 31)), '3.10');
      expect(charge(r, d(2027, 1, 31)), '2.30');
      expect(r.series.syncs.single.calculated, dec('-1000'));
      expect(
          r.series.points
              .firstWhere((p) => p.date == d(2027, 1, 15))
              .closingBalance,
          dec('-500'));
    });

    test('a charge day is absorbed by the drift', () {
      final r =
          walk([loan(), sync('s1', '-900', d(2027, 1, 31))], d(2027, 1, 31));
      expect(r.series.points.last.closingBalance, dec('-900'));
      // The month-end interest still posts, before the pin.
      expect(charge(r, d(2027, 1, 31)), '3.10');
      expect(r.series.syncs.single.calculated, dec('-1003.10'));
      expect(r.series.syncs.single.drift, dec('103.10'));
      final occ = [
        for (final o in r.series.occurrences)
          if (o.date == d(2027, 1, 31)) o.component
      ];
      expect(occ, ['interest', 'sync']);
    });

    test('a sync to zero pays it off; a negative sync re-borrows', () {
      // On a charge day (month end): nothing accrued is left, so the loan
      // is paid off from that day.
      final paid =
          walk([loan(), sync('z', '0', d(2027, 1, 31))], d(2027, 2, 28));
      expect(paid.payoffDate, d(2027, 1, 31));
      expect(charge(paid, d(2027, 2, 28)), '0.00');
      // Mid-month: the interest accrued before the sync carries on; with
      // nothing owed the next day it is charged as the payout interest.
      final mid =
          walk([loan(), sync('z', '0', d(2027, 2, 10))], d(2027, 2, 12));
      final payout = mid.charges.singleWhere((c) => c.date == d(2027, 2, 11));
      expect((payout.amount.toStringAsFixed(2), payout.payout), ('1.00', true));
      final again = walk([
        loan(),
        sync('z', '0', d(2027, 1, 31)),
        sync('n', '-300', d(2027, 3, 1)),
      ], d(2027, 3, 31));
      expect(again.payoffDate, isNull);
      // March accrues on 300 for Mar 2–31 (30 days): 0.90.
      expect(charge(again, d(2027, 3, 31)), '0.90');
    });

    test('a flat loan keeps its instalment schedule through a sync', () {
      final base = walk([loan(interest: 'flat')], d(2027, 4, 30));
      final r = walk(
          [loan(interest: 'flat'), sync('s', '-800', d(2027, 2, 15))],
          d(2027, 4, 30));
      expect([for (final c in r.charges) (c.date, c.amount)],
          [for (final c in base.charges) (c.date, c.amount)]);
      expect(
          r.series.points
              .firstWhere((p) => p.date == d(2027, 2, 15))
              .closingBalance,
          dec('-800'));
    });

    test('BalanceEngine.compute on a loan stream reports the syncs', () {
      final series = BalanceEngine.compute(
        seedBalance: Decimal.zero,
        seedDate: s,
        events: [loan(), sync('s1', '-500', d(2027, 1, 15))],
        eventOrder: const [],
        from: d(2027, 1, 20),
        to: d(2027, 1, 31),
      );
      expect(series.syncs.single.eventId, 's1');
      expect(series.occurrences.any((o) => o.component == 'sync'), isFalse);
    });

    test("an offset stream's sync changes the loan's interest from that day",
        () {
      BudgetStream stream(String id, String seed) => BudgetStream(
            id: id,
            ownerId: 'o',
            name: id,
            seedBalance: dec(seed),
            seedDate: s,
            lossThreshold: Decimal.zero,
            displayOrder: 0,
            eventOrder: const [],
          );
      String janInterest(List<BudgetEvent> offsetEvents) {
        final group = LoanGroup(
            [OffsetSource(stream: stream('off', '400'), events: offsetEvents)]);
        final series = group.compute(
            stream: stream('loan', '0'),
            events: [loan()],
            from: s,
            to: d(2027, 1, 31));
        return [
          for (final o in series.occurrences)
            if (o.derived) (-o.signedDelta).toStringAsFixed(2)
        ].join(',');
      }

      // 600 owed net of a 400 offset: 31 × 0.06 = 1.86.
      expect(janInterest(const []), '1.86');
      // The offset synced to 0 on Jan 16: Jan 16–31 on 1000 (16 × 0.10)
      // plus Jan 1–15 on 600 (15 × 0.06) = 2.50.
      expect(janInterest([sync('os', '0', d(2027, 1, 16))]), '2.50');
    });
  });

  test('a transfer into a synced stream leaves the peer unaffected', () {
    // A's side of the transfer (debit) and A's sync; B holds the credit.
    final aSide = ev('ta', Direction.debit, '50', d(2027, 1, 5));
    final bSide = ev('tb', Direction.credit, '50', d(2027, 1, 5));
    final a = run([aSide, sync('s', '1000', d(2027, 1, 5))]);
    final b = run([bSide]);
    expect(close(a, d(2027, 1, 5)), '1000.00');
    expect(close(b, d(2027, 1, 5)), '150.00');
  });
}
