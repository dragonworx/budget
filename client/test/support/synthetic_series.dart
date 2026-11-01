// Deterministic synthetic streams for the timeline perf harness (spec 005
// R2): the same shapes server/tool/perf_seed.dart writes to a perf DB,
// built in memory. Every value comes from a seeded generator, so goldens
// and benchmarks see identical data on every run.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/combined.dart';
import 'package:decimal/decimal.dart';

import 'fake_loans.dart';

/// Small seeded LCG (Numerical Recipes constants): stable across platforms.
class SynthRandom {
  SynthRandom(int seed) : _s = seed & 0x7fffffff;
  int _s;
  int next(int max) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % max;
  }
}

enum SynthCadence { daily, weekly, fortnightly, monthly }

/// Event mix for a target size at 35 years (see perf_seed.dart's sizes).
typedef SynthMix = ({int daily, int weekly, int fortnightly, int monthly});

const Map<String, SynthMix> perfMixes = {
  'PERF 5k': (daily: 0, weekly: 2, fortnightly: 2, monthly: 2),
  'PERF 50k': (daily: 2, weekly: 8, fortnightly: 6, monthly: 20),
  'PERF 200k': (daily: 12, weekly: 20, fortnightly: 10, monthly: 40),
  'PERF 1M': (daily: 70, weekly: 30, fortnightly: 20, monthly: 60),
};

/// One synthetic stream: its series and what the chart needs about it.
class SynthStream {
  SynthStream({
    required this.id,
    required this.name,
    required this.seedDate,
    required this.seedCents,
    required this.series,
    required this.events,
    this.thresholdCents = 0,
    this.loanPayoffs = const {},
  });

  final String id;
  final String name;
  final DateTime seedDate;
  final int seedCents;
  final BalanceSeries series;
  final List<BudgetEvent> events;
  final int thresholdCents;
  final Map<String, DateTime> loanPayoffs;

  double get seedBalance => seedCents / 100;
  double get lossThreshold => thresholdCents / 100;
  Map<String, String> get names => {for (final e in events) e.id: e.name};
  Map<String, BudgetEvent> get byId => {for (final e in events) e.id: e};
  List<String> get order => [for (final e in events) e.id];
}

DateTime _day(DateTime d, int offset) =>
    DateTime(d.year, d.month, d.day + offset);
Decimal _money(int cents) => Decimal.fromInt(cents).shift(-2);

const _labels = [
  'Salary',
  'Rent',
  'Groceries',
  'Coffee',
  'Power bill',
  'Phone plan',
  'Car rego',
  'Insurance',
  'Gym',
  'Streaming',
  'Dividends',
  'Side gig',
];

bool _occurs(SynthCadence c, DateTime start, DateTime d, int dayIndex) {
  final since = dayIndex;
  if (since < 0) return false;
  return switch (c) {
    SynthCadence.daily => true,
    SynthCadence.weekly => since % 7 == 0,
    SynthCadence.fortnightly => since % 14 == 0,
    SynthCadence.monthly => d.day == start.day,
  };
}

BudgetEvent _event(
  String streamId,
  String id,
  String name,
  bool credit,
  int cents,
  DateTime start,
  SynthCadence c,
) => BudgetEvent(
  id: id,
  streamId: streamId,
  name: name,
  direction: credit ? EventDirection.credit : EventDirection.debit,
  amount: _money(cents),
  startDate: start,
  recurrenceMode: RecurrenceMode.every,
  interval: c == SynthCadence.fortnightly ? 2 : 1,
  unit: switch (c) {
    SynthCadence.daily => RecurrenceUnit.days,
    SynthCadence.weekly || SynthCadence.fortnightly => RecurrenceUnit.weeks,
    SynthCadence.monthly => RecurrenceUnit.months,
  },
  endMode: EndMode.never,
);

/// A stream of paired events (a credit and a debit of the same cadence and
/// amount, a few days apart) so the balance oscillates: the alert
/// threshold (the median close) is crossed many times. About 2% of the
/// occurrences are skipped. [mix] sets how many of each cadence (even
/// counts: events come in pairs).
SynthStream syntheticStream({
  String id = 's',
  String name = 'PERF',
  required DateTime seedDate,
  required SynthMix mix,
  int days = 12785 + 730,
  int seed = 1,
  int seedCents = 500000,
}) {
  final rnd = SynthRandom(seed);
  final cadences = [
    for (var i = 0; i < mix.daily; i++) SynthCadence.daily,
    for (var i = 0; i < mix.weekly; i++) SynthCadence.weekly,
    for (var i = 0; i < mix.fortnightly; i++) SynthCadence.fortnightly,
    for (var i = 0; i < mix.monthly; i++) SynthCadence.monthly,
  ];
  final events = <BudgetEvent>[];
  final specs =
      <
        ({String id, bool credit, int cents, int startOffset, SynthCadence c})
      >[];
  var cents = 0, base = 0, gap = 0;
  for (final (i, c) in cadences.indexed) {
    // Pairs: the credit, then the debit of the same cadence and amount.
    final credit = i.isEven;
    if (credit) {
      cents = switch (c) {
        SynthCadence.daily => 300 + rnd.next(1500),
        SynthCadence.weekly => 2000 + rnd.next(20000),
        SynthCadence.fortnightly => 50000 + rnd.next(150000),
        SynthCadence.monthly => 5000 + rnd.next(200000),
      };
      base = rnd.next(24);
      gap = 1 + rnd.next(4);
    }
    // Every other pair spends first, so the balance dips under its seed.
    final spendFirst = (i ~/ 2).isOdd;
    final startOffset = base + (credit == spendFirst ? gap : 0);
    final evId = '$id-e$i';
    final label = _labels[(i ~/ 2) % _labels.length];
    events.add(
      _event(
        id,
        evId,
        '$label ${i ~/ 2 + 1}${credit ? '' : ' out'}',
        credit,
        cents,
        _day(seedDate, startOffset),
        c,
      ),
    );
    specs.add((
      id: evId,
      credit: credit,
      cents: cents,
      startOffset: startOffset,
      c: c,
    ));
  }
  final occ = <Occurrence>[];
  final points = <BalancePoint>[];
  var bal = seedCents;
  final closes = <int>[];
  for (var d = 0; d < days; d++) {
    final date = _day(seedDate, d);
    for (final s in specs) {
      final start = _day(seedDate, s.startOffset);
      if (!_occurs(s.c, start, date, d - s.startOffset)) continue;
      final skipped = rnd.next(50) == 0;
      final delta = s.credit ? s.cents : -s.cents;
      if (!skipped) bal += delta;
      occ.add(
        Occurrence(
          eventId: s.id,
          date: date,
          signedDelta: _money(delta),
          skipped: skipped,
        ),
      );
    }
    points.add(BalancePoint(date: date, closingBalance: _money(bal)));
    closes.add(bal);
  }
  // The alert threshold: the median close, so the line crosses it often.
  closes.sort();
  return SynthStream(
    id: id,
    name: name,
    seedDate: seedDate,
    seedCents: seedCents,
    series: BalanceSeries(points: points, occurrences: occ),
    events: events,
    thresholdCents: closes[closes.length ~/ 2],
  );
}

/// A reducing-rate loan stream (drawdown, monthly interest, monthly
/// repayments transferred in from "Wages") with an offset stream lowering
/// the interest, paid off within the range. Returns the loan stream; its
/// [SynthStream.loanPayoffs] holds the payoff day.
SynthStream syntheticLoan({
  String id = 'loan',
  required DateTime seedDate,
  int days = 12785 + 730,
  int principalCents = 45000000,
  int repaymentCents = 320000,
  int offsetCents = 3000000,
  int ratePpm = 61000, // 6.1% a year
}) {
  String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final start = _day(seedDate, 15);
  final loan = loanEvent(
    id: '$id-loan',
    streamId: id,
    amount: (principalCents ~/ 100).toString(),
    start: ymd(start),
    terms: loanTermsJson(start: ymd(start), rate: '6.1'),
  );
  final repay = BudgetEvent(
    id: '$id-repay',
    streamId: id,
    name: 'Repayment',
    direction: EventDirection.credit,
    amount: _money(repaymentCents),
    startDate: _day(start, 30),
    recurrenceMode: RecurrenceMode.every,
    interval: 1,
    unit: RecurrenceUnit.months,
    endMode: EndMode.never,
    transfer: const TransferLink(
      peerStreamId: 'wages',
      peerStreamName: 'Wages',
    ),
  );
  final occ = <Occurrence>[];
  final points = <BalancePoint>[];
  var owed = 0; // cents owed (positive)
  var accrued = 0.0;
  DateTime? payoff;
  for (var d = 0; d < days; d++) {
    final date = _day(seedDate, d);
    if (payoff == null) {
      if (date == start) {
        owed = principalCents;
        occ.add(
          Occurrence(
            eventId: loan.id,
            date: date,
            signedDelta: _money(-principalCents),
          ),
        );
      } else if (owed > 0) {
        accrued += (owed - offsetCents).clamp(0, owed) * ratePpm / 1e6 / 365;
        if (date.day == start.day) {
          final interest = accrued.round();
          accrued = 0;
          owed += interest;
          occ.add(
            Occurrence(
              eventId: loan.id,
              date: date,
              signedDelta: _money(-interest),
              component: 'interest',
              derived: true,
            ),
          );
        }
        if (date.day == _day(start, 30).day &&
            !date.isBefore(_day(start, 30))) {
          final pay = owed < repaymentCents ? owed : repaymentCents;
          owed -= pay;
          occ.add(
            Occurrence(eventId: repay.id, date: date, signedDelta: _money(pay)),
          );
          if (owed == 0) {
            payoff = date;
            final last = accrued.round();
            occ.add(
              Occurrence(
                eventId: loan.id,
                date: date,
                signedDelta: _money(-last),
                component: 'interest',
                derived: true,
                payout: true,
              ),
            );
            owed += last;
            accrued = 0;
          }
        }
      }
    }
    points.add(BalancePoint(date: date, closingBalance: _money(-owed)));
  }
  return SynthStream(
    id: id,
    name: 'Mortgage',
    seedDate: seedDate,
    seedCents: 0,
    series: BalanceSeries(points: points, occurrences: occ),
    events: [loan, repay],
    loanPayoffs: {loan.id: ?payoff},
  );
}

/// The current stream combined with two others (three streams), one
/// transfer between the current stream and the first other netting out.
class SynthCombined {
  SynthCombined(this.current, this.others, this.series, this.lineStart);
  final SynthStream current;
  final List<SynthStream> others;
  final BalanceSeries series;
  final DateTime lineStart;

  Map<String, CombinedStream> get streams => {
    for (final (i, o) in others.indexed)
      o.id: CombinedStream(
        id: o.id,
        name: o.name,
        color: combinedStreamColor(i),
        canEdit: true,
      ),
  };
  Map<String, BudgetEvent> get otherEvents => {
    for (final o in others) ...o.byId,
  };
  Map<String, String> get names => {
    ...current.names,
    for (final o in others) ...o.names,
  };
  List<String> get otherOrder => [for (final o in others) ...o.order];
}

SynthCombined syntheticCombined({
  required DateTime seedDate,
  int days = 12785 + 730,
}) {
  final a = syntheticStream(
    id: 'a',
    name: 'Everyday',
    seedDate: seedDate,
    mix: (daily: 0, weekly: 2, fortnightly: 0, monthly: 2),
    days: days,
    seed: 11,
  );
  final b = syntheticStream(
    id: 'b',
    name: 'Savings',
    seedDate: _day(seedDate, -40),
    mix: (daily: 0, weekly: 0, fortnightly: 2, monthly: 2),
    days: days + 40,
    seed: 22,
    seedCents: 1500000,
  );
  final c = syntheticStream(
    id: 'c',
    name: 'Business',
    seedDate: _day(seedDate, 20),
    mix: (daily: 0, weekly: 2, fortnightly: 0, monthly: 2),
    days: days - 20,
    seed: 33,
    seedCents: 250000,
  );
  // A monthly transfer a -> b (both included: netted).
  final outId = 'a-xfer', inId = 'b-xfer';
  final xferOut = BudgetEvent(
    id: outId,
    streamId: 'a',
    name: 'To savings',
    direction: EventDirection.debit,
    amount: _money(40000),
    startDate: _day(seedDate, 3),
    recurrenceMode: RecurrenceMode.every,
    interval: 1,
    unit: RecurrenceUnit.months,
    endMode: EndMode.never,
    transfer: const TransferLink(peerStreamId: 'b', peerEventId: 'b-xfer'),
  );
  final xferIn = BudgetEvent(
    id: inId,
    streamId: 'b',
    name: 'From everyday',
    direction: EventDirection.credit,
    amount: _money(40000),
    startDate: _day(seedDate, 3),
    recurrenceMode: RecurrenceMode.every,
    interval: 1,
    unit: RecurrenceUnit.months,
    endMode: EndMode.never,
    transfer: const TransferLink(peerStreamId: 'a', peerEventId: 'a-xfer'),
  );
  SynthStream withTransfer(SynthStream s, BudgetEvent t, int sign) {
    final occ = [...s.series.occurrences];
    final points = <BalancePoint>[];
    var shift = 0;
    var k = 0;
    for (final p in s.series.points) {
      final d = p.date;
      if (!d.isBefore(t.startDate) && d.day == t.startDate.day) {
        shift += sign * 40000;
        occ.add(
          Occurrence(eventId: t.id, date: d, signedDelta: _money(sign * 40000)),
        );
      }
      points.add(
        BalancePoint(date: d, closingBalance: p.closingBalance + _money(shift)),
      );
      k++;
    }
    assert(k == s.series.points.length);
    occ.sort((x, y) => x.date.compareTo(y.date));
    return SynthStream(
      id: s.id,
      name: s.name,
      seedDate: s.seedDate,
      seedCents: s.seedCents,
      series: BalanceSeries(points: points, occurrences: occ),
      events: [...s.events, t],
      thresholdCents: s.thresholdCents,
    );
  }

  final a2 = withTransfer(a, xferOut, -1);
  final b2 = withTransfer(b, xferIn, 1);
  CombinedPart part(SynthStream s) => CombinedPart(
    streamId: s.id,
    seedDate: s.seedDate,
    series: s.series,
    events: s.events,
  );
  final others = [b2, c];
  return SynthCombined(
    a2,
    others,
    combineSeries(part(a2), [for (final o in others) part(o)]),
    combinedLineStart(part(a2), [for (final o in others) part(o)]),
  );
}
