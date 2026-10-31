// The loan walk inside the balance engine (spec 002): goldens from
// /workspace/specs/loan-ref/loan_ref.py driven through
// BalanceEngine.compute with real events, plus engine behaviour.
import 'package:budget_loan/budget_loan.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:budget_server/engine/loan_walk.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);
Decimal dec(String v) => Decimal.parse(v);
String f(DateTime x) => formatDate(x);

LoanTerms terms(
  DateTime start,
  String rate, {
  int termMonths = 360,
  String interest = 'reducing',
  String freq = 'monthly',
  String? schedule,
  Object? chargeDay,
  String dayCount = '365',
  List<(DateTime, String)> more = const [],
  DateTime? first,
}) =>
    LoanTerms.fromJson({
      'v': 1,
      'mode': more.isEmpty ? 'simple' : 'advanced',
      'interestType': interest,
      'termMonths': termMonths,
      'repaymentFrequency': freq,
      if (first != null) 'firstRepaymentDate': f(first),
      if (schedule != null) 'chargeSchedule': schedule,
      if (chargeDay != null) 'chargeDay': chargeDay,
      if (interest != 'flat') 'dayCount': dayCount,
      'ratePeriods': [
        {'from': f(start), 'ratePct': rate},
        for (final (from, r) in more)
          {'from': f(from), 'ratePct': r, 'type': 'variable'},
      ],
    }).withDefaults(start);

BudgetEvent loanEvent(DateTime start, String amount, LoanTerms t,
        {bool enabled = true, bool hidden = false}) =>
    BudgetEvent(
      id: 'loan',
      streamId: 's',
      name: 'Loan',
      direction: Direction.debit,
      amount: dec(amount),
      startDate: start,
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
      enabled: enabled,
      categoryHidden: hidden,
      createdAt: DateTime.utc(2020),
      kind: EventKind.loan,
      loan: t,
    );

BudgetEvent ev(String id, Direction dir, String amount, DateTime start,
        {RecurrenceUnit? unit, int interval = 1, int? count}) =>
    BudgetEvent(
      id: id,
      streamId: 's',
      name: id,
      direction: dir,
      amount: dec(amount),
      startDate: start,
      recurrenceMode: unit == null ? RecurrenceMode.once : RecurrenceMode.every,
      interval: unit == null ? null : interval,
      unit: unit,
      endMode: count == null ? EndMode.never : EndMode.count,
      occurrenceCount: count,
      enabled: true,
      createdAt: DateTime.utc(2021),
    );

BudgetEvent monthly(String amount, DateTime first, int count,
        [String id = 'repay']) =>
    ev(id, Direction.credit, amount, first,
        unit: RecurrenceUnit.months, count: count);

BudgetEvent fortnightly(String amount, DateTime first, int count) =>
    ev('repay', Direction.credit, amount, first,
        unit: RecurrenceUnit.weeks, interval: 2, count: count);

LoanWalkResult walk(List<BudgetEvent> events, DateTime until,
    {DateTime? seed, DateTime? from, List<String> order = const []}) {
  final loan = LoanWalk.activeLoan(events)!;
  final s = seed ?? loan.startDate;
  return LoanWalk.compute(
    seedBalance: Decimal.zero,
    seedDate: s,
    events: events,
    eventOrder: order,
    from: from ?? s,
    to: until,
    loan: loan,
  );
}

Decimal closeOn(LoanWalkResult r, DateTime day) =>
    r.series.points.firstWhere((p) => p.date == day).closingBalance;

Decimal total(LoanWalkResult r) =>
    r.charges.fold(Decimal.zero, (a, c) => a + c.amount);

List<String> amounts(LoanWalkResult r, [int n = 3]) =>
    [for (final c in r.charges.take(n)) c.amount.toStringAsFixed(2)];

void main() {
  group('goldens', () {
    test('G1 monthEnd 365 and G1b actual leap year', () {
      final s = d(2027, 1, 1);
      final r = walk(
          [loanEvent(s, '1000', terms(s, '3.65', chargeDay: 'monthEnd'))],
          d(2027, 3, 31));
      expect(amounts(r), ['3.10', '2.81', '3.12']);
      expect([for (final c in r.charges) f(c.date)],
          ['2027-01-31', '2027-02-28', '2027-03-31']);
      expect(closeOn(r, d(2027, 3, 31)), dec('-1009.03'));
      final s2 = d(2028, 1, 1);
      final r2 = walk([
        loanEvent(s2, '1000',
            terms(s2, '3.66', chargeDay: 'monthEnd', dayCount: 'actual'))
      ], d(2028, 3, 31));
      expect(amounts(r2), ['3.10', '2.91', '3.12']);
      expect(closeOn(r2, d(2028, 3, 31)), dec('-1009.13'));
    });

    test('G2 personal loan, anniversary, 12 repayments', () {
      final s = d(2027, 1, 15);
      final r = walk([
        loanEvent(s, '10000', terms(s, '12', termMonths: 12)),
        monthly('888.49', d(2027, 2, 15), 12),
      ], d(2028, 6, 30));
      expect(amounts(r), ['101.92', '84.81', '85.71']);
      expect(r.charges.last.amount, dec('8.93'));
      expect(f(r.charges.last.date), '2028-01-15');
      expect(total(r), dec('658.91'));
      expect(closeOn(r, d(2028, 1, 15)), dec('2.97'));
      expect(r.payoffDate, d(2028, 1, 15));
      expect(closeOn(r, d(2027, 2, 15)), dec('-9213.43'));
    });

    test('G3 mortgage: monthly 365 / actual, fortnightly', () {
      final s = d(2027, 1, 15);
      final end = d(2057, 1, 15);
      final r = walk([
        loanEvent(s, '500000', terms(s, '6')),
        monthly('2997.76', d(2027, 2, 15), 360),
      ], end);
      expect(r.charges.first.amount, dec('2547.95'));
      expect(closeOn(r, end), dec('-1030.45'));
      expect(total(r), dec('580224.05'));
      final ra = walk([
        loanEvent(s, '500000', terms(s, '6', dayCount: 'actual')),
        monthly('2997.76', d(2027, 2, 15), 360),
      ], end);
      expect(closeOn(ra, end), dec('358.83'));
      expect(total(ra), dec('578834.77'));
      // Fortnightly 1,383.59 from 2027-01-29 through 2057-01-15.
      final rf = walk([
        loanEvent(s, '500000', terms(s, '6', freq: 'fortnightly')),
        fortnightly('1383.59', d(2027, 1, 29), 783),
      ], end);
      expect(rf.payoffDate, d(2056, 9, 15));
      expect(total(rf), dec('569896.50'));
      expect(amounts(rf, 2), ['2543.40', '2295.79']);
    });

    test('G4 rate change: B at the boundary and the new minimum', () {
      final s = d(2027, 3, 1);
      final t = terms(s, '5.50', more: [(d(2029, 3, 1), '6.50')]);
      final r = walk([
        loanEvent(s, '300000', t),
        monthly('1703.37', d(2027, 4, 1), 23),
      ], d(2029, 3, 1));
      expect(closeOn(r, d(2029, 2, 28)), dec('-292213.69'));
      expect(r.charges.last.amount, dec('1232.90'));
      expect(r.owedAtBoundary[d(2029, 3, 1)], dec('293446.59'));
      final mins = minimums(t, s, dec('300000'), r.owedAtBoundary);
      expect(mins.first.amount, dec('1703.37'));
      expect(mins[1].amount, dec('1898.65'));
      expect(mins[1].reason, 'rateChange');
    });

    test('G5 on repayment dates, fortnightly; G7 charge day 1', () {
      final s = d(2027, 1, 1);
      final r = walk([
        loanEvent(
            s,
            '1000',
            terms(s, '3.65',
                freq: 'fortnightly', schedule: 'onRepaymentDates')),
      ], d(2027, 2, 12));
      expect(amounts(r), ['1.40', '1.40', '1.40']);
      expect(closeOn(r, d(2027, 2, 12)), dec('-1004.20'));
      final s7 = d(2027, 1, 15);
      final r7 = walk([loanEvent(s7, '1000', terms(s7, '3.65', chargeDay: 1))],
          d(2027, 3, 1));
      expect(amounts(r7, 2), ['1.70', '2.80']);
      expect(closeOn(r7, d(2027, 3, 1)), dec('-1004.50'));
    });

    test('G6 fortnightly charged on repayment dates', () {
      final s = d(2027, 1, 15);
      final r = walk([
        loanEvent(s, '500000',
            terms(s, '6', freq: 'fortnightly', schedule: 'onRepaymentDates')),
        fortnightly('1383.59', d(2027, 1, 29), 782),
      ], d(2057, 1, 15));
      expect(amounts(r), ['1150.68', '1150.15', '1149.61']);
      expect(r.payoffDate, d(2056, 10, 13));
      expect(total(r), dec('572459.28'));
    });

    test('F1 flat monthly, F3 early payoff without rebate', () {
      final s = d(2027, 1, 15);
      final t = terms(s, '10', termMonths: 24, interest: 'flat');
      final r = walk([
        loanEvent(s, '10000', t),
        monthly('500', d(2027, 2, 15), 24),
      ], d(2029, 6, 1));
      expect(r.charges, hasLength(24));
      expect(r.charges.first.amount, dec('83.33'));
      expect(r.charges.first.flat, isTrue);
      expect(r.charges.last.amount, dec('83.41'));
      expect(closeOn(r, d(2029, 1, 15)), Decimal.zero);
      expect(r.payoffDate, d(2029, 1, 15));
      expect(total(r), dec('2000'));
      final occ = r.series.occurrences.firstWhere((o) => o.derived);
      expect(occ.toJson()['flat'], isTrue);

      final r3 = walk([
        loanEvent(s, '10000', t),
        monthly('500', d(2027, 2, 15), 12),
        ev('clear', Direction.credit, '4999.96', d(2028, 2, 1)),
        ev('rest', Direction.credit, '1000.04', d(2028, 2, 2)),
      ], d(2029, 6, 1));
      expect(closeOn(r3, d(2028, 1, 31)), dec('-4999.96'));
      final p = r3.charges.firstWhere((c) => c.payout);
      expect(f(p.date), '2028-02-01');
      expect(p.amount, dec('1000.04'));
      expect(closeOn(r3, d(2028, 2, 1)), dec('-1000.04'));
      expect(r3.payoffDate, d(2028, 2, 2));
      expect(total(r3), dec('2000'));
    });
  });

  group('engine behaviour', () {
    final s = d(2027, 1, 1);
    // 3.65% / 365: one cent a day per $100 owed. Charged at month end.
    LoanTerms t() => terms(s, '3.65', chargeDay: 'monthEnd', termMonths: 12);

    test('BalanceEngine.compute delegates only for an active loan', () {
      final events = [loanEvent(s, '1000', t())];
      final viaEngine = BalanceEngine.compute(
        seedBalance: Decimal.zero,
        seedDate: s,
        events: events,
        eventOrder: const [],
        from: s,
        to: d(2027, 1, 31),
      );
      expect(viaEngine.points.last.closingBalance, dec('-1003.10'));
      final interest = viaEngine.occurrences.where((o) => o.derived).single;
      expect(interest.toJson(), {
        'eventId': 'loan',
        'date': '2027-01-31',
        'signedDelta': '-3.1',
        'skipped': false,
        'component': 'interest',
        'derived': true,
      });
      for (final off in [
        loanEvent(s, '1000', t(), enabled: false),
        loanEvent(s, '1000', t(), hidden: true),
      ]) {
        final x = BalanceEngine.compute(
          seedBalance: Decimal.zero,
          seedDate: s,
          events: [off],
          eventOrder: const [],
          from: s,
          to: d(2027, 2, 28),
        );
        expect(x.points.last.closingBalance, Decimal.zero);
        expect(x.occurrences, isEmpty);
      }
    });

    test('a fee accrues from the next day; extra repayment cuts interest', () {
      final base = walk([loanEvent(s, '1000', t())], d(2027, 1, 31));
      expect(base.charges.single.amount, dec('3.10'));
      // $100 fee on 21 Jan: 11 days (21..31) on 1,100 -> +0.11.
      final fee = walk([
        loanEvent(s, '1000', t()),
        ev('fee', Direction.debit, '100', d(2027, 1, 21)),
      ], d(2027, 1, 31));
      expect(fee.charges.single.amount, dec('3.21'));
      final extra = walk([
        loanEvent(s, '1000', t()),
        ev('extra', Direction.credit, '500', d(2027, 1, 21)),
      ], d(2027, 1, 31));
      expect(extra.charges.single.amount, dec('2.55'));
      // A redraw (debit) raises it like the fee.
      final redraw = walk([
        loanEvent(s, '1000', t()),
        ev('redraw', Direction.debit, '100', d(2027, 1, 21)),
      ], d(2027, 1, 31));
      expect(redraw.charges.single.amount, dec('3.21'));
    });

    test('payoff stops interest with a payout; negative again restarts', () {
      final r = walk([
        loanEvent(s, '1000', t()),
        ev('payoff', Direction.credit, '1000', d(2027, 1, 11)),
        ev('fee', Direction.debit, '100', d(2027, 2, 1)),
      ], d(2027, 2, 28));
      // 10 days (1..10) on 1,000 = 1.00, charged on payoff day.
      expect(r.charges.first.payout, isTrue);
      expect(f(r.charges.first.date), '2027-01-11');
      expect(r.charges.first.amount, dec('1.00'));
      expect(closeOn(r, d(2027, 1, 11)), dec('-1.00'));
      // Owing 1.00 from 11 Jan to 31 Jan accrues 21 × 0.0001 → 0.00: no
      // charge; then the fee restarts interest: 28 × 101 × 0.0001 = 0.28.
      final feb = r.charges.where((c) => c.date.month == 2).single;
      expect(feb.amount, dec('0.28'));
      expect(r.payoffDate, isNull);
      final clear = walk([
        loanEvent(s, '1000', t()),
        ev('payoff', Direction.credit, '1001', d(2027, 1, 11)),
      ], d(2027, 3, 31));
      expect(clear.payoffDate, d(2027, 1, 11));
      expect(clear.charges, hasLength(1));
      expect(closeOn(clear, d(2027, 3, 31)), Decimal.zero);
    });

    test(
        'derived ordering: start-of-day charges before the day, monthEnd '
        'after', () {
      final s2 = d(2027, 1, 15);
      final r = walk([
        loanEvent(s2, '10000', terms(s2, '12', termMonths: 12)),
        monthly('888.49', d(2027, 2, 15), 12),
      ], d(2027, 2, 15));
      final day = r.series.occurrences.where((o) => o.date == d(2027, 2, 15));
      expect([for (final o in day) o.derived ? 'interest' : o.eventId],
          ['interest', 'repay']);
      final me = walk([
        loanEvent(s, '1000', t()),
        ev('pay', Direction.credit, '10', d(2027, 1, 31)),
      ], d(2027, 1, 31));
      final last = me.series.occurrences.where((o) => o.date == d(2027, 1, 31));
      expect([for (final o in last) o.derived ? 'interest' : o.eventId],
          ['pay', 'interest']);
    });

    test('a window starting mid-loan gives the full walk balances', () {
      final s2 = d(2027, 1, 15);
      final events = [
        loanEvent(s2, '10000', terms(s2, '12', termMonths: 12)),
        monthly('888.49', d(2027, 2, 15), 12),
      ];
      final full = walk(events, d(2027, 12, 31), seed: d(2027, 1, 1));
      final part = walk(events, d(2027, 12, 31),
          seed: d(2027, 1, 1), from: d(2027, 6, 10));
      expect(part.series.points.first.date, d(2027, 6, 10));
      for (final p in part.series.points) {
        expect(closeOn(full, p.date), p.closingBalance);
      }
      expect(
          part.series.occurrences
              .every((o) => !o.date.isBefore(d(2027, 6, 10))),
          isTrue);
      expect(part.charges.length, full.charges.length);
    });
  });
}
