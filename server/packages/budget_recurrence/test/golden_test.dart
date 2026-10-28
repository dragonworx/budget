import 'dart:io';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:test/test.dart';

import '../tool/golden.dart';

/// The pre-structured generator (server occurrence_gen before migration
/// 023): start + k·N days / weeks / months (months rolled from the start's
/// own day; years as 12 months).
List<DateTime> legacyDates(
  DateTime start,
  int n,
  String unit,
  DateTime from,
  DateTime to, {
  DateTime? until,
  int? count,
}) {
  final out = <DateTime>[];
  for (var i = 0; i < 100000; i++) {
    if (count != null && i >= count) break;
    final steps = n * i;
    final c = switch (unit) {
      'days' => DateTime.utc(start.year, start.month, start.day + steps),
      'weeks' => DateTime.utc(start.year, start.month, start.day + 7 * steps),
      'months' => addMonthsRolled(start, steps),
      _ => addMonthsRolled(start, steps * 12),
    };
    if (until != null && c.isAfter(until)) break;
    if (c.isAfter(to)) break;
    if (!c.isBefore(from)) out.add(c);
  }
  return out;
}

void main() {
  test('golden_vectors.json is up to date (dart run tool/golden.dart)', () {
    expect(File('test/golden_vectors.json').readAsStringSync(), goldenJson());
  });

  test(
      'every legacy cadence gives byte-identical dates through the '
      'structured rule (lossless backfill)', () {
    var checked = 0;
    for (final unit in ['days', 'weeks', 'months', 'years']) {
      for (final n in [1, 2, 3, 5, 6, 12]) {
        for (var s = DateTime.utc(2023, 12, 25);
            s.isBefore(DateTime.utc(2024, 4, 3));
            s = s.add(const Duration(days: 3))) {
          for (final (until, count) in <(DateTime?, int?)>[
            (null, null),
            (DateTime.utc(2027, 2, 28), null),
            (null, 9),
          ]) {
            final from = DateTime.utc(2023, 1, 1),
                to = DateTime.utc(2032, 1, 1);
            final f =
                Frequency.fromLegacy(once: false, interval: n, unit: unit);
            expect(
              fireDates(f, s, from: from, to: to, until: until, count: count),
              legacyDates(s, n, unit, from, to, until: until, count: count),
              reason: '$unit $n from $s',
            );
            checked++;
          }
        }
      }
    }
    expect(checked, greaterThan(2000));
  });
}
