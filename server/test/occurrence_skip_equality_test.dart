// Spec 005 R10: the skip lookup is a set of calendar-day keys; it must mark
// exactly the occurrences the old linear scan did (byte-identical output).
import 'dart:math';

import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/calendar_math.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

/// The pre-R10 generator, kept verbatim as the reference.
List<Occurrence> _linear(
  List<BudgetEvent> events,
  DateTime from,
  DateTime to,
  Map<String, Set<DateTime>> skipped,
) {
  final windowStart = CalendarMath.dateOnly(from);
  final windowEnd = CalendarMath.dateOnly(to);
  final out = <Occurrence>[];
  for (final event in events) {
    if (!event.active) continue;
    for (final date in OccurrenceGenerator.datesForEvent(
      event,
      windowStart,
      windowEnd,
    )) {
      final skipSet = skipped[event.id] ?? const <DateTime>{};
      final isSkipped = skipSet.any((d) => CalendarMath.compare(d, date) == 0);
      out.add(
        Occurrence(
          eventId: event.id,
          date: date,
          signedDelta: event.signedAmountOn(date),
          skipped: isSkipped,
        ),
      );
    }
  }
  return out;
}

String _key(Occurrence o) =>
    '${o.eventId}|${o.date.toIso8601String()}|${o.signedDelta}|${o.skipped}';

void main() {
  test('skip set marks exactly what the linear scan did (1000 cases)', () {
    final rnd = Random(20261101);
    const units = RecurrenceUnit.values;
    var compared = 0, skippedSeen = 0;
    for (var c = 0; c < 1000; c++) {
      final start = DateTime.utc(
          2020 + rnd.nextInt(10), 1 + rnd.nextInt(12), 1 + rnd.nextInt(28));
      final events = [
        for (var e = 0; e < 1 + rnd.nextInt(4); e++)
          BudgetEvent(
            id: 'e$e',
            streamId: 's',
            name: 'E$e',
            direction: rnd.nextBool() ? Direction.credit : Direction.debit,
            amount: Decimal.fromInt(1 + rnd.nextInt(5000)),
            startDate: start.add(Duration(days: rnd.nextInt(60))),
            recurrenceMode: RecurrenceMode.every,
            interval: 1 + rnd.nextInt(3),
            unit: units[rnd.nextInt(units.length)],
            endMode: EndMode.never,
            enabled: rnd.nextInt(10) != 0,
            createdAt: DateTime.utc(2020),
          ),
      ];
      final from = start.subtract(Duration(days: rnd.nextInt(30)));
      final to = from.add(Duration(days: 30 + rnd.nextInt(800)));
      // Skips: some on occurrence days (in UTC and local midnight forms,
      // with times of day), some on random days.
      final skipped = <String, Set<DateTime>>{};
      for (final e in events) {
        if (rnd.nextInt(4) == 0) continue;
        final dates = OccurrenceGenerator.datesForEvent(e, from, to);
        final set = <DateTime>{};
        for (var k = 0; k < rnd.nextInt(12); k++) {
          if (dates.isNotEmpty && rnd.nextBool()) {
            final d = dates[rnd.nextInt(dates.length)];
            set.add(switch (rnd.nextInt(3)) {
              0 => d,
              1 => DateTime(d.year, d.month, d.day),
              _ => DateTime.utc(d.year, d.month, d.day, rnd.nextInt(24)),
            });
          } else {
            set.add(from.add(Duration(days: rnd.nextInt(900))));
          }
        }
        skipped[e.id] = set;
      }
      final want = _linear(events, from, to, skipped).map(_key).toList();
      final got = OccurrenceGenerator.generate(
        events: events,
        from: from,
        to: to,
        skipped: skipped,
      ).map(_key).toList();
      expect(got, want, reason: 'case $c');
      compared += got.length;
      skippedSeen += got.where((k) => k.endsWith('true')).length;
    }
    expect(compared, greaterThan(10000));
    expect(skippedSeen, greaterThan(500));
  });
}
