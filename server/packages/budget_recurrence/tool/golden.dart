import 'dart:convert';
import 'dart:io';

import 'package:budget_recurrence/budget_recurrence.dart';

/// Builds the shared golden vectors: every rule with and without days, odd
/// starts, ends by date and by count. The server and client test suites
/// both replay `test/golden_vectors.json` through their own event models,
/// so they must agree with the engine and with each other.
List<Map<String, Object?>> goldenCases() {
  String f(DateTime x) => x.toIso8601String().substring(0, 10);
  final freqs = <Frequency>[
    Frequency.once,
    Frequency(FreqRule.daily),
    Frequency(FreqRule.daily, interval: 3),
    Frequency(FreqRule.weekly),
    Frequency(FreqRule.weekly, days: [1, 2]),
    Frequency(FreqRule.weekly, days: [7]),
    Frequency(FreqRule.everyNWeeks, interval: 2),
    Frequency(FreqRule.everyNWeeks, interval: 2, days: [1, 3]),
    Frequency(FreqRule.everyNWeeks, interval: 3, days: [5, 6, 7]),
    Frequency(FreqRule.monthly),
    Frequency(FreqRule.monthly, days: [1, 15]),
    Frequency(FreqRule.monthly, days: [31]),
    Frequency(FreqRule.monthly, days: [29, 30, 31]),
    Frequency(FreqRule.everyNMonths, interval: 3, days: [31]),
    Frequency(FreqRule.everyNMonths, interval: 2, days: [1, 5]),
    Frequency(FreqRule.everyNMonths, interval: 12),
  ];
  final starts = [
    DateTime.utc(2026, 10, 8),
    DateTime.utc(2024, 1, 31),
    DateTime.utc(2026, 12, 29),
    DateTime.utc(2028, 2, 29),
  ];
  final out = <Map<String, Object?>>[];
  for (final fr in freqs) {
    for (final s in starts) {
      for (final (until, count) in <(DateTime?, int?)>[
        (null, null),
        (s.add(const Duration(days: 75)), null),
        (null, 7),
      ]) {
        final from = s.subtract(const Duration(days: 3));
        final to = DateTime.utc(s.year + 1, s.month, 1);
        out.add({
          'frequency': fr.toJson(),
          'start': f(s),
          'until': until == null ? null : f(until),
          'count': count,
          'from': f(from),
          'to': f(to),
          'dates': [
            for (final x in fireDates(fr, s,
                from: from, to: to, until: until, count: count))
              f(x),
          ],
          'phrase': describeFrequency(fr, s),
          'compact': describeFrequency(fr, s, compact: true),
        });
      }
    }
  }
  return out;
}

String goldenJson() =>
    '${const JsonEncoder.withIndent(' ').convert(goldenCases())}\n';

void main() {
  File('test/golden_vectors.json').writeAsStringSync(goldenJson());
  stdout.writeln('wrote ${goldenCases().length} cases');
}
