// The synthetic perf data has the shapes spec 005 R2 asks for.
import 'package:flutter_test/flutter_test.dart';

import '../support/synthetic_series.dart';

void main() {
  final seed = DateTime(2100);

  test('PERF stream: all cadences, skips, threshold crossed >= 5 times', () {
    final s = syntheticStream(seedDate: seed, mix: perfMixes['PERF 50k']!);
    expect(s.series.occurrences.length, inInclusiveRange(45000, 65000));
    expect(s.series.occurrences.where((o) => o.skipped), isNotEmpty);
    var crossings = 0;
    bool? below;
    for (final p in s.series.points) {
      final now = p.closingBalance.toDouble() < s.lossThreshold;
      if (below != null && now != below) crossings++;
      below = now;
    }
    expect(crossings, greaterThanOrEqualTo(5));
    final again = syntheticStream(seedDate: seed, mix: perfMixes['PERF 50k']!);
    expect(again.series.occurrences.length, s.series.occurrences.length);
    expect(again.thresholdCents, s.thresholdCents);
  });

  test('PERF loan is paid off within the range', () {
    final loan = syntheticLoan(seedDate: seed);
    expect(loan.loanPayoffs.values.whereType<DateTime>(), hasLength(1));
  });

  test('PERF combined has three streams', () {
    final c = syntheticCombined(seedDate: seed);
    expect(1 + c.others.length, 3);
    expect(c.streams, hasLength(2));
  });
}
