import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/selection_period.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime d(int day) => DateTime(2026, 10, day);
Occurrence o(int day, num v, {bool skipped = false, String id = 't'}) =>
    Occurrence(
      transactionId: id,
      date: d(day),
      signedDelta: Decimal.parse('$v'),
      skipped: skipped,
    );

/// Seed 1000 on 1 Oct; +500 on 3rd, −200 on 5th, +500 skipped on 8th,
/// −50 and +20 on 10th.
final occ = [
  o(3, 500, id: 'pay'),
  o(5, -200, id: 'rent'),
  o(8, 500, skipped: true, id: 'pay'),
  o(10, -50, id: 'food'),
  o(10, 20, id: 'refund'),
];

BalanceSeries daily() {
  final pts = <BalancePoint>[];
  var bal = 1000.0;
  for (var i = 1; i <= 20; i++) {
    for (final x in occ) {
      if (x.date == d(i) && !x.skipped) bal += x.signedDelta.toDouble();
    }
    pts.add(BalancePoint(date: d(i), closingBalance: Decimal.parse('$bal')));
  }
  return BalanceSeries(points: pts, occurrences: occ);
}

void main() {
  test('opening of start day, close of end day, gains and losses', () {
    final s = summarizePeriod(
      series: daily(),
      start: d(4),
      end: d(10),
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.startBalance, 1500); // close of 3 Oct
    expect(s.endBalance, 1270); // 1500 − 200 − 50 + 20
    expect(s.net, -230);
    expect(s.gains, 20);
    expect(s.losses, -250);
    expect(s.gains + s.losses, s.net);
    expect(s.percent, closeTo(-15.333, 0.001));
    expect(s.days, 7);
    expect(s.occurrences.map((x) => x.transactionId), [
      'rent',
      'food',
      'refund',
    ]);
  });

  test('skipped occurrences neither count nor list', () {
    final s = summarizePeriod(
      series: daily(),
      start: d(7),
      end: d(9),
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.occurrences, isEmpty);
    expect(s.gains, 0);
    expect(s.net, 0);
  });

  test('a range starting on the seed day opens at the seed balance', () {
    final s = summarizePeriod(
      series: daily(),
      start: d(3),
      end: d(1), // reversed: ordered automatically
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.start, d(1));
    expect(s.end, d(3));
    expect(s.startBalance, 1000);
    expect(s.endBalance, 1500);
    expect(s.gains, 500);
  });

  test('sparse points: balance carries forward between change days', () {
    final full = daily();
    final sparse = BalanceSeries(
      points: [
        for (final p in full.points)
          if (occ.any((x) => x.date == p.date && !x.skipped) || p.date == d(1))
            p,
      ],
      occurrences: occ,
    );
    final s = summarizePeriod(
      series: sparse,
      start: d(6),
      end: d(12),
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.startBalance, 1300);
    expect(s.endBalance, 1270);
  });

  test('before the first loaded point it walks back from that point', () {
    final full = daily();
    final late = BalanceSeries(
      points: full.points.where((p) => !p.date.isBefore(d(6))).toList(),
      occurrences: occ,
    );
    final s = summarizePeriod(
      series: late,
      start: d(4),
      end: d(10),
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.startBalance, 1500);
    expect(s.endBalance, 1270);
  });

  test('no percentage from a zero or negative start', () {
    final s = summarizePeriod(
      series: const BalanceSeries(points: []),
      start: d(2),
      end: d(4),
      seedDate: d(1),
      seedBalance: 0,
    );
    expect(s.percent, isNull);
  });

  test('lowest point and first alert day in the range', () {
    final s = summarizePeriod(
      series: daily(),
      start: d(4),
      end: d(12),
      seedDate: d(1),
      seedBalance: 1000,
      threshold: 1290,
    );
    // 1500 on 4th, 1300 from 5th, 1270 from 10th.
    expect(s.lowestBalance, 1270);
    expect(s.lowestDate, d(10));
    expect(s.alertDate, d(10));
  });

  test('no alert day when the balance stays above the threshold', () {
    final s = summarizePeriod(
      series: daily(),
      start: d(1),
      end: d(20),
      seedDate: d(1),
      seedBalance: 1000,
    );
    expect(s.alertDate, isNull);
    expect(s.lowestBalance, 1000);
  });
}
