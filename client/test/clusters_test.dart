import 'dart:math' as math;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/clusters.dart';
import 'package:budget_client/features/timeline/lod.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// A seeded random stream: events with overrides (odd cents), skips,
/// netted transfers (combined view), loan interest and an offset stream.
({List<Occurrence> occ, Map<int, int> closeByDay, int seedDay}) _stream(
  int seed,
) {
  final r = math.Random(seed);
  final start = DateTime(
    2000 + r.nextInt(30),
    1 + r.nextInt(12),
    1 + r.nextInt(28),
  );
  final days = 30 + r.nextInt(r.nextBool() ? 400 : 4000);
  final events = List.generate(1 + r.nextInt(7), (i) => 'e$i');
  final occ = <Occurrence>[];
  for (var i = 0; i < 1 + r.nextInt(120); i++) {
    final d = DateTime(start.year, start.month, start.day + r.nextInt(days));
    final cents =
        (r.nextBool() ? 1 : -1) *
        r.nextInt(r.nextInt(10) == 0 ? 200000000 : 500000);
    final kind = r.nextInt(10);
    occ.add(
      Occurrence(
        eventId: kind == 9 ? 'loan' : events[r.nextInt(events.length)],
        date: d,
        signedDelta: Decimal.fromInt(cents).shift(-2),
        skipped: kind == 0,
        netted: kind == 1,
        streamId: kind == 2 ? 'offset' : null,
        component: kind == 9 ? 'interest' : null,
        derived: kind == 9,
      ),
    );
  }
  // The balance: every counted, un-netted occurrence (interest included).
  final byDay = <int, int>{};
  for (final o in occ) {
    if (o.skipped || o.netted) continue;
    final k = dayIndexOf(o.date);
    byDay[k] = (byDay[k] ?? 0) + decimalCents(o.signedDelta);
  }
  final seedDay = dayIndexOf(start) - 1;
  final closes = <int, int>{};
  var bal = r.nextInt(1000000);
  for (var d = seedDay; d <= dayIndexOf(start) + days; d++) {
    bal += byDay[d] ?? 0;
    closes[d] = bal;
  }
  return (occ: occ, closeByDay: closes, seedDay: seedDay);
}

void main() {
  test('calendar bins: keys round-trip, ISO weeks start Monday', () {
    for (var i = -2000; i < 20000; i += 7) {
      final d = DateTime(1970, 1, 1 + i);
      for (final p in BinPeriod.values) {
        final k = binKeyOf(p, d);
        expect(binStart(p, k).isAfter(d), isFalse, reason: '$p $d');
        expect(binEnd(p, k).isAfter(d), isTrue, reason: '$p $d');
        expect(binKeyOf(p, binStart(p, k)), k);
      }
      expect(
        binStart(BinPeriod.week, binKeyOf(BinPeriod.week, d)).weekday,
        DateTime.monday,
      );
    }
    expect(
      binLabel(
        BinPeriod.month,
        binKeyOf(BinPeriod.month, DateTime(2031, 3, 9)),
      ),
      'Mar 2031',
    );
    expect(
      binLabel(
        BinPeriod.quarter,
        binKeyOf(BinPeriod.quarter, DateTime(2031, 2, 9)),
      ),
      '1 Jan – 31 Mar 2031',
    );
    expect(
      binLabel(BinPeriod.year, binKeyOf(BinPeriod.year, DateTime(2031, 2, 9))),
      '2031',
    );
  });

  test('period choice: 35y is years on a phone, quarters on desktop', () {
    const days35 = 12785;
    expect(binPeriodFor(390 / days35), BinPeriod.year);
    expect(binPeriodFor(1600 / days35), BinPeriod.quarter);
    expect(binPeriodFor(6.0), BinPeriod.day);
    expect(binPeriodFor(1.0), BinPeriod.week);
  });

  test('group accuracy: 1,000 seeded streams, every bin at every level', () {
    var bins = 0;
    for (var seed = 0; seed < 1000; seed++) {
      final s = _stream(seed);
      final c = groupClustersOf(s.occ);
      for (final p in BinPeriod.values) {
        final level = c.level(p);
        var sumNet = 0, sumInterest = 0, sumCount = 0;
        for (final b in level.bins) {
          bins++;
          final inBin = [
            for (final o in s.occ)
              if (binKeyOf(p, o.date) == b.key) o,
          ];
          int cents(Occurrence o) => decimalCents(o.signedDelta);
          bool counted(Occurrence o) =>
              !o.skipped && !o.netted && !isInterest(o);
          expect(b.total, inBin.length);
          expect(b.count, inBin.where(counted).length);
          expect(b.skipped, inBin.where((o) => o.skipped).length);
          expect(
            b.creditCents,
            inBin
                .where(counted)
                .map(cents)
                .where((v) => v > 0)
                .fold(0, (a, v) => a + v),
          );
          expect(
            b.debitCents,
            -inBin
                .where(counted)
                .map(cents)
                .where((v) => v < 0)
                .fold(0, (a, v) => a + v),
          );
          expect(
            b.netCents,
            inBin.where(counted).map(cents).fold(0, (a, v) => a + v),
          );
          final interest = inBin.where((o) => !o.skipped && isInterest(o));
          expect(b.interestCount, interest.length);
          expect(b.interestCents, interest.map(cents).fold(0, (a, v) => a + v));
          // Top 3 + remainder add up exactly.
          expect(b.top.length, lessThanOrEqualTo(3));
          expect(
            b.top.fold(0, (a, l) => a + l.count) + b.remainderCount,
            b.count,
          );
          expect(
            b.top.fold(0, (a, l) => a + l.cents) + b.remainderCents,
            b.netCents,
          );
          expect(c.linesOf(b).fold(0, (a, l) => a + l.cents), b.netCents);
          for (var i = 1; i < b.top.length; i++) {
            expect(
              b.top[i - 1].cents.abs(),
              greaterThanOrEqualTo(b.top[i].cents.abs()),
            );
          }
          // Balance identity over the whole calendar period.
          final open =
              s.closeByDay[dayIndexOf(b.start) - 1] ?? s.closeByDay[s.seedDay]!;
          final closeDay = math.min(
            dayIndexOf(b.end) - 1,
            s.closeByDay.keys.reduce(math.max),
          );
          expect(
            s.closeByDay[closeDay]! - open,
            b.netCents + b.interestCents,
            reason: 'seed $seed $p ${b.key}',
          );
          sumNet += b.netCents;
          sumInterest += b.interestCents;
          sumCount += b.count;
          // Labels: always "net" and the exact count; "~" iff inexact.
          final text = groupLabelText(b, (id) => id);
          expect(text.amount, startsWith('net '));
          if (b.singleEventId == null || b.count == 0) {
            expect(text.lines.first, startsWith(groupCountText(b.count)));
          } else {
            expect(text.lines.first, endsWith('×${groupCountText(b.count)}'));
          }
          expect(text.amount.contains('~'), _inexact(text.amount, b.netCents));
          expect(
            text.lines.any((l) => l.startsWith('interest')),
            b.interestCount > 0,
          );
        }
        // Sum over all bins = sum of raw occurrences.
        final counted = s.occ.where(
          (o) => !o.skipped && !o.netted && !isInterest(o),
        );
        expect(
          sumNet,
          counted.fold(0, (a, o) => a + decimalCents(o.signedDelta)),
        );
        expect(sumCount, counted.length);
        expect(
          sumInterest,
          s.occ
              .where((o) => !o.skipped && isInterest(o))
              .fold(0, (a, o) => a + decimalCents(o.signedDelta)),
        );
      }
    }
    expect(bins, greaterThan(40000));
  });

  test('range queries cover exactly the bins that overlap', () {
    final s = _stream(7);
    final level = groupClustersOf(s.occ).level(BinPeriod.month);
    final from = s.occ.first.date, to = from.add(const Duration(days: 200));
    final (a, b) = level.range(from, to);
    for (var i = 0; i < level.bins.length; i++) {
      final bin = level.bins[i];
      final overlaps = bin.end.isAfter(from) && bin.start.isBefore(to);
      expect(i >= a && i < b, overlaps, reason: '${bin.start}');
    }
  });

  test('money text: exact to the cent, "~" only when compacted inexactly', () {
    expect(groupMoneyText(-123456), '−\$1,234.56');
    expect(groupMoneyText(2400000), '+\$24,000.00');
    expect(groupMoneyText(120000000), '+\$1.2M');
    expect(groupMoneyText(-123456789), '~−\$1.23M');
    expect(groupMoneyText(0), '\$0.00');
    final b = groupClustersOf([
      for (var i = 0; i < 12; i++)
        Occurrence(
          eventId: 'rent',
          date: DateTime(2031, 1 + i, 1),
          signedDelta: Decimal.fromInt(-2000),
        ),
    ]).level(BinPeriod.year).bins.single;
    final t = groupLabelText(b, (_) => 'Rent');
    expect('${t.lines.first} · ${t.amount}', 'Rent ×12 · net −\$24,000.00');
  });

  test('label budget: K by |net|, stable ties, sticky across frames', () {
    final occ = [
      for (var i = 0; i < 40; i++)
        Occurrence(
          eventId: 'e${i % 3}',
          date: DateTime(2031, 1 + i ~/ 2, 1 + i % 2),
          signedDelta: Decimal.fromInt((i % 5) * 100),
        ),
    ];
    final bins = groupClustersOf(occ).level(BinPeriod.month).bins;
    final k3 = labelBudget(bins, 3);
    expect(k3.length, 3);
    expect(labelBudget(bins, 3).map((b) => b.key), k3.map((b) => b.key));
    // A label shown last frame keeps its slot over a larger newcomer.
    final small = bins.firstWhere(
      (b) => b.netCents.abs() < k3.last.netCents.abs(),
    );
    final sticky = labelBudget(bins, 3, previous: {small.key});
    expect(sticky.map((b) => b.key), contains(small.key));
    expect(groupLabelBudget(390), 3);
    expect(groupLabelBudget(1600), 13);
  });

  test('every level is built once per occurrence list', () {
    final s = _stream(3);
    final before = debugGroupBuilds;
    final c = groupClustersOf(s.occ)..prewarm();
    c.prewarm();
    groupClustersOf(s.occ).level(BinPeriod.year);
    expect(debugGroupBuilds - before, BinPeriod.values.length);
  });
}

bool _inexact(String amount, int cents) {
  // Parse the shown figure back to cents.
  final m = RegExp(r'([−+]?)\$([\d,]+(?:\.\d+)?)([MB]?)').firstMatch(amount)!;
  var v = double.parse(m.group(2)!.replaceAll(',', ''));
  if (m.group(3) == 'M') v *= 1e6;
  if (m.group(3) == 'B') v *= 1e9;
  final shown = (v * 100).round() * (m.group(1) == '−' ? -1 : 1);
  return shown != cents;
}
