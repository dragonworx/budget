// Spec 004 (loan offset account) through the server engine: goldens O1–O10
// (loan $100,000 drawn 2027-01-01, 3.65% / 365, monthEnd: one cent a day
// per $100 owed; offset stream seeded 2027-01-01 at $40,000, threshold 0)
// driven via LoanGroup + BalanceEngine.compute, the benefit figures of the
// loan summary (G3 inputs + a $50,000 offset), and that the offset stream's
// own series and non-loan streams are untouched.
import 'package:budget_loan/budget_loan.dart';
import 'package:budget_server/api/loan_summary.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_engine.dart';
import 'package:budget_server/engine/stream_group.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

import 'loan_walk_test.dart' show d, dec, ev, f, fortnightly, loanEvent, terms;

BudgetStream stream(String id,
        {String seed = '0', DateTime? seedDate, String threshold = '0'}) =>
    BudgetStream(
      id: id,
      ownerId: 'o',
      name: id == 'off' ? 'Everyday' : 'Home loan',
      seedBalance: dec(seed),
      seedDate: seedDate ?? d(2027, 1, 1),
      lossThreshold: dec(threshold),
      displayOrder: 0,
      eventOrder: const [],
    );

final s = d(2027, 1, 1);
LoanTerms t({String? schedule, String freq = 'monthly', DateTime? first}) =>
    terms(s, '3.65',
        chargeDay: schedule == null ? 'monthEnd' : null,
        schedule: schedule,
        freq: freq,
        first: first);

/// The loan stream's balance with [offset] (null: unlinked) through [to].
BalanceSeries run({
  List<BudgetEvent>? loanEvents,
  OffsetSource? offset,
  DateTime? to,
}) {
  final group = offset == null ? LoanGroup.none : LoanGroup([offset]);
  return group.compute(
    stream: stream('loan'),
    events: loanEvents ?? [loanEvent(s, '100000', t())],
    from: s,
    to: to ?? d(2027, 1, 31),
  );
}

OffsetSource offset(
        {String seed = '40000',
        DateTime? seedDate,
        String threshold = '0',
        List<BudgetEvent> events = const []}) =>
    OffsetSource(
      stream:
          stream('off', seed: seed, seedDate: seedDate, threshold: threshold),
      events: events,
    );

List<String> charges(BalanceSeries r) => [
      for (final o in r.occurrences)
        if (o.derived) '${f(o.date)} ${(-o.signedDelta).toStringAsFixed(2)}'
    ];

void main() {
  test('O1 no offset: 310.00', () {
    expect(charges(run()), ['2027-01-31 310.00']);
  });

  test('O2 linked: Jan 186.00, Feb 168.52', () {
    expect(charges(run(offset: offset(), to: d(2027, 2, 28))),
        ['2027-01-31 186.00', '2027-02-28 168.52']);
  });

  test('O3 threshold 10,000: 217.00', () {
    expect(charges(run(offset: offset(threshold: '10000'))),
        ['2027-01-31 217.00']);
  });

  test('O4 offset above owed: no interest occurrence', () {
    final r = run(offset: offset(seed: '150000'));
    expect(charges(r), isEmpty);
    expect(r.points.last.closingBalance, dec('-100000'));
  });

  test('O5 same-day transfer offset -> loan: base stays 60,000', () {
    final out = ev('xfer', Direction.debit, '2000', d(2027, 1, 15));
    final inn = ev('xfer', Direction.credit, '2000', d(2027, 1, 15));
    expect(
        charges(run(
          loanEvents: [loanEvent(s, '100000', t()), inn],
          offset: offset(events: [out]),
        )),
        ['2027-01-31 186.00']);
  });

  test('O6 same-day deposit into the offset: 177.50', () {
    final salary = ev('salary', Direction.credit, '5000', d(2027, 1, 15));
    expect(
        charges(run(offset: offset(events: [salary]))), ['2027-01-31 177.50']);
  });

  test('O7 negative offset never offsets (threshold 0 and -1,000)', () {
    expect(charges(run(offset: offset(seed: '-500'))), ['2027-01-31 310.00']);
    expect(charges(run(offset: offset(seed: '-500', threshold: '-1000'))),
        ['2027-01-31 310.00']);
  });

  test('T1-T4 threshold goldens through the engine', () {
    for (final (seed, z, want) in [
      ('40000', '10000', '217.00'),
      ('40000', '0', '186.00'),
      ('40000', '-1000', '186.00'),
      ('-500', '-1000', '310.00'),
    ]) {
      expect(charges(run(offset: offset(seed: seed, threshold: z))),
          ['2027-01-31 $want'],
          reason: 'seed $seed threshold $z');
    }
  });

  test('O8 offset seeded 2027-01-11: 226.00', () {
    expect(charges(run(offset: offset(seedDate: d(2027, 1, 11)))),
        ['2027-01-31 226.00']);
  });

  test('O9 offsetApplies false: same as no offset for that period', () {
    LoanTerms periods(bool second) => LoanTerms.fromJson({
          'v': 1,
          'mode': 'advanced',
          'interestType': 'reducing',
          'termMonths': 360,
          'repaymentFrequency': 'monthly',
          'chargeDay': 'monthEnd',
          'dayCount': '365',
          'ratePeriods': [
            {
              'from': '2027-01-01',
              'ratePct': '3.65',
              'type': 'fixed',
              'offsetApplies': false
            },
            {
              'from': '2027-02-01',
              'ratePct': '3.65',
              'type': 'variable',
              'offsetApplies': second
            },
          ],
        }).withDefaults(s);
    final r = run(
        loanEvents: [loanEvent(s, '100000', periods(true))],
        offset: offset(),
        to: d(2027, 2, 28));
    // Jan: no offset (310.00); Feb: (100,310 - 40,000) x 0.0001 x 28.
    expect(charges(r), ['2027-01-31 310.00', '2027-02-28 168.87']);
    final none = run(
        loanEvents: [loanEvent(s, '100000', periods(false))],
        offset: offset(),
        to: d(2027, 2, 28));
    expect(charges(none), charges(run(to: d(2027, 2, 28))));
  });

  test('O10 charged on repayment dates: first charge 84.00', () {
    final tt = t(
        schedule: 'onRepaymentDates',
        freq: 'fortnightly',
        first: d(2027, 1, 15));
    final r = run(
        loanEvents: [loanEvent(s, '100000', tt)],
        offset: offset(),
        to: d(2027, 1, 20));
    expect(charges(r), ['2027-01-15 84.00']);
  });

  test('the offset stream\'s own series is unchanged by the link', () {
    final o = offset(events: [
      ev('salary', Direction.credit, '5000', d(2027, 1, 15)),
    ]);
    BalanceSeries own() => BalanceEngine.compute(
          seedBalance: o.stream.seedBalance,
          seedDate: o.stream.seedDate,
          events: o.events,
          eventOrder: const [],
          from: s,
          to: d(2027, 3, 31),
        );
    String snap(BalanceSeries x) => [
          for (final p in x.points) '${f(p.date)} ${p.closingBalance}',
          for (final q in x.occurrences) '${f(q.date)} ${q.signedDelta}',
        ].join(';');
    final before = snap(own());
    run(offset: o, to: d(2027, 3, 31));
    expect(snap(own()), before);
    // Usable: max(0, close - max(0, threshold)), zero days left out.
    final u = o.usableThrough(d(2027, 1, 20));
    expect(u[d(2027, 1, 14)], dec('40000'));
    expect(u[d(2027, 1, 15)], dec('45000'));
    expect(offset(seed: '-1').usableThrough(d(2027, 1, 5)), isEmpty);
  });

  test('benefit: G3 mortgage with a constant 50,000 offset', () {
    final g3 = d(2027, 1, 15);
    // G3's fortnightly inputs (the monthly ones leave -1,030.45 owed at
    // term end, so they never pay off and have no payoff to compare).
    final events = [
      loanEvent(g3, '500000', terms(g3, '6', freq: 'fortnightly')),
      fortnightly('1383.59', d(2027, 1, 29), 783),
    ];
    final ls = stream('loan', seedDate: g3);
    final without =
        loanSummary(stream: ls, events: events, skipped: const {}, from: g3)!;
    final withOff = loanSummary(
      stream: ls,
      events: events,
      skipped: const {},
      from: g3,
      offsets: LoanGroup([offset(seed: '50000', seedDate: d(2027, 1, 1))]),
    )!;
    expect(without['offset'], isNull);
    // G3 unchanged without the link.
    expect((without['charges'] as List).first['interest'], '2543.40');
    expect(without['payoffDate'], '2056-09-15');
    final o = withOff['offset'] as Map;
    expect(o['streamId'], 'off');
    expect(o['visible'], isTrue);
    expect(o['usableToday'], '50000.00');
    expect(o['thresholdUsed'], '0.00');
    expect(o['totalInterestWithoutOffset'], without['totalInterest']);
    expect(o['payoffDateWithoutOffset'], without['payoffDate']);
    final saved = Decimal.parse(o['interestSaved'] as String);
    expect(saved, greaterThan(Decimal.zero));
    expect(
        saved,
        Decimal.parse(without['totalInterest'] as String) -
            Decimal.parse(withOff['totalInterest'] as String));
    expect(
        DateTime.parse(withOff['payoffDate'] as String)
            .isBefore(DateTime.parse(without['payoffDate'] as String)),
        isTrue);
    expect(o['monthsSaved'], greaterThan(0));
    // The repayment transfer is the same amount.
    expect(withOff['repaymentTransfers'], without['repaymentTransfers']);
    expect(monthsBetween(d(2050, 1, 15), d(2052, 3, 14)), 25);
    expect(monthsBetween(d(2052, 3, 14), d(2050, 1, 15)), -25);
  });
}
