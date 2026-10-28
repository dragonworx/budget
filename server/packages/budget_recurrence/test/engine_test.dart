import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:test/test.dart';

DateTime d(int y, int m, int day) => DateTime.utc(y, m, day);
String fmt(DateTime x) =>
    '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
List<String> fire(
  Frequency f,
  DateTime start, {
  DateTime? from,
  DateTime? to,
  DateTime? until,
  int? count,
}) =>
    [
      for (final x in fireDates(f, start,
          from: from ?? start,
          to: to ?? d(2100, 1, 1),
          until: until,
          count: count))
        fmt(x),
    ];
List<String> take(Frequency f, DateTime start, int n) =>
    [for (final x in fireSequence(f, start).take(n)) fmt(x)];

void main() {
  group('Frequency validation', () {
    test('canonicalises N and sorts / dedupes days', () {
      final f = Frequency(FreqRule.weekly, interval: 2, days: [3, 1, 3]);
      expect(f.rule, FreqRule.everyNWeeks);
      expect(f.days, [1, 3]);
      expect(
          Frequency(FreqRule.everyNMonths, interval: 1).rule, FreqRule.monthly);
    });
    test('rejects days for once / daily and out-of-range values', () {
      expect(() => Frequency(FreqRule.once, days: [1]), throwsFormatException);
      expect(() => Frequency(FreqRule.daily, days: [1]), throwsFormatException);
      expect(
          () => Frequency(FreqRule.weekly, days: [0]), throwsFormatException);
      expect(
          () => Frequency(FreqRule.weekly, days: [8]), throwsFormatException);
      expect(
          () => Frequency(FreqRule.monthly, days: [32]), throwsFormatException);
      expect(() => Frequency(FreqRule.monthly, interval: 0),
          throwsFormatException);
      expect(
          () => Frequency(FreqRule.once, interval: 2), throwsFormatException);
    });
    test('json round trip and legacy mapping', () {
      final f = Frequency(FreqRule.everyNMonths, interval: 3, days: [31]);
      expect(Frequency.fromJson(f.toJson()), f);
      expect(Frequency.fromJson({'rule': 'everyNWeeks', 'interval': '2'}).rule,
          FreqRule.everyNWeeks);
      expect(Frequency.fromLegacy(once: false, interval: 1, unit: 'years'),
          Frequency(FreqRule.everyNMonths, interval: 12));
      expect(Frequency.fromLegacy(once: false, interval: 2, unit: 'weeks'),
          Frequency(FreqRule.everyNWeeks, interval: 2));
      expect(Frequency.fromLegacy(once: true), Frequency.once);
      expect(Frequency(FreqRule.everyNWeeks, interval: 2).legacyUnit, 'weeks');
    });
  });

  group('six rules without days (legacy cadence)', () {
    test('once', () {
      expect(fire(Frequency.once, d(2026, 10, 8)), ['2026-10-08']);
      expect(fire(Frequency.once, d(2026, 10, 8), from: d(2026, 10, 9)), []);
    });
    test('daily, every 3 days', () {
      expect(take(Frequency(FreqRule.daily), d(2026, 12, 30), 4),
          ['2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02']);
      expect(take(Frequency(FreqRule.daily, interval: 3), d(2026, 2, 27), 3),
          ['2026-02-27', '2026-03-02', '2026-03-05']);
    });
    test('weekly / every 2 weeks: the start weekday', () {
      expect(take(Frequency(FreqRule.weekly), d(2026, 10, 8), 3),
          ['2026-10-08', '2026-10-15', '2026-10-22']);
      expect(
          take(Frequency(FreqRule.everyNWeeks, interval: 2), d(2026, 10, 8), 3),
          ['2026-10-08', '2026-10-22', '2026-11-05']);
    });
    test('monthly / every N months: start day, rolled, never drifting', () {
      expect(take(Frequency(FreqRule.monthly), d(2024, 1, 31), 4),
          ['2024-01-31', '2024-02-29', '2024-03-31', '2024-04-30']);
      expect(
          take(Frequency(FreqRule.everyNMonths, interval: 3), d(2025, 11, 30),
              3),
          ['2025-11-30', '2026-02-28', '2026-05-30']);
      expect(
          take(Frequency(FreqRule.everyNMonths, interval: 12), d(2024, 2, 29),
              3),
          ['2024-02-29', '2025-02-28', '2026-02-28']);
    });
  });

  group('weekly with days', () {
    test('Mon, Tue every week from a Thursday start: first is next Mon', () {
      // 8 Oct 2026 is a Thursday.
      expect(take(Frequency(FreqRule.weekly, days: [1, 2]), d(2026, 10, 8), 4),
          ['2026-10-12', '2026-10-13', '2026-10-19', '2026-10-20']);
    });
    test(
        'start on a chosen day fires that day; days before it in the '
        'start week never fire', () {
      // Wed 7 Oct 2026, Mon/Wed/Fri.
      expect(
          take(Frequency(FreqRule.weekly, days: [1, 3, 5]), d(2026, 10, 7), 4),
          ['2026-10-07', '2026-10-09', '2026-10-12', '2026-10-14']);
    });
    test('every 2 weeks anchored to the start week, across a year end', () {
      // Tue 22 Dec 2026: live weeks are those of 21 Dec, 4 Jan, 18 Jan.
      expect(
          take(Frequency(FreqRule.everyNWeeks, interval: 2, days: [1, 3]),
              d(2026, 12, 22), 5),
          [
            '2026-12-23',
            '2027-01-04',
            '2027-01-06',
            '2027-01-18',
            '2027-01-20'
          ]);
    });
    test('every 3 weeks on Sun (week ends on Sunday)', () {
      // Mon 5 Oct 2026 → Sun 11 Oct, then +3 weeks.
      expect(
          take(Frequency(FreqRule.everyNWeeks, interval: 3, days: [7]),
              d(2026, 10, 5), 3),
          ['2026-10-11', '2026-11-01', '2026-11-22']);
    });
    test('DST changes (Sydney 4 Oct 2026, 5 Apr 2026) do not shift days', () {
      expect(take(Frequency(FreqRule.weekly, days: [6, 7]), d(2026, 4, 1), 4),
          ['2026-04-04', '2026-04-05', '2026-04-11', '2026-04-12']);
      expect(take(Frequency(FreqRule.weekly, days: [7]), d(2026, 9, 27), 3),
          ['2026-09-27', '2026-10-04', '2026-10-11']);
    });
    test('the same as no days when the only day is the start weekday', () {
      final a = take(Frequency(FreqRule.everyNWeeks, interval: 2, days: [4]),
          d(2026, 10, 8), 20);
      expect(
          a,
          take(Frequency(FreqRule.everyNWeeks, interval: 2), d(2026, 10, 8),
              20));
    });
  });

  group('monthly with days', () {
    test('1st and 15th from mid-month', () {
      expect(
          take(Frequency(FreqRule.monthly, days: [1, 15]), d(2026, 10, 8), 4),
          ['2026-10-15', '2026-11-01', '2026-11-15', '2026-12-01']);
    });
    test('31st rolls to the last day (Feb leap and not, 30-day months)', () {
      expect(take(Frequency(FreqRule.monthly, days: [31]), d(2024, 1, 1), 5), [
        '2024-01-31',
        '2024-02-29',
        '2024-03-31',
        '2024-04-30',
        '2024-05-31'
      ]);
      expect(take(Frequency(FreqRule.monthly, days: [29]), d(2025, 1, 1), 3),
          ['2025-01-29', '2025-02-28', '2025-03-29']);
      expect(take(Frequency(FreqRule.monthly, days: [30]), d(2028, 2, 1), 2),
          ['2028-02-29', '2028-03-30']);
    });
    test('two days rolling onto the same date fire once', () {
      expect(
          take(Frequency(FreqRule.monthly, days: [29, 30, 31]), d(2026, 2, 1),
              4),
          ['2026-02-28', '2026-03-29', '2026-03-30', '2026-03-31']);
    });
    test('every 3 months on the 31st, counted from the start month', () {
      expect(
          take(Frequency(FreqRule.everyNMonths, interval: 3, days: [31]),
              d(2026, 11, 5), 4),
          ['2026-11-30', '2027-02-28', '2027-05-31', '2027-08-31']);
    });
    test('a start after this month\'s days waits for the next live month', () {
      expect(
          take(Frequency(FreqRule.everyNMonths, interval: 2, days: [1, 5]),
              d(2026, 10, 20), 3),
          ['2026-12-01', '2026-12-05', '2027-02-01']);
    });
  });

  group('ends, windows and counts', () {
    test('until date is inclusive', () {
      expect(
          fire(Frequency(FreqRule.weekly, days: [1, 2]), d(2026, 10, 8),
              until: d(2026, 10, 19)),
          ['2026-10-12', '2026-10-13', '2026-10-19']);
    });
    test('count counts firings of multi-day rules, from the start', () {
      final f = Frequency(FreqRule.monthly, days: [1, 15]);
      expect(fire(f, d(2026, 10, 8), count: 3),
          ['2026-10-15', '2026-11-01', '2026-11-15']);
      // A window after the start still counts from the start.
      expect(fire(f, d(2026, 10, 8), count: 3, from: d(2026, 11, 2)),
          ['2026-11-15']);
      expect(nthFireDate(f, d(2026, 10, 8), 4), d(2026, 12, 1));
      expect(nthFireDate(f, d(2026, 10, 8), 4, until: d(2026, 11, 30)), isNull);
    });
    test('trim from here = until the day before', () {
      final f = Frequency(FreqRule.weekly, days: [1, 2]);
      final trimmed = fire(f, d(2026, 10, 8), until: d(2026, 10, 19));
      expect(trimmed.last, '2026-10-19');
      expect(firesOn(f, d(2026, 10, 8), d(2026, 10, 20)), isTrue);
      expect(firesOn(f, d(2026, 10, 8), d(2026, 10, 21)), isFalse);
    });
    test('empty and reversed windows', () {
      expect(
          fire(Frequency(FreqRule.daily), d(2026, 1, 1),
              from: d(2026, 2, 1), to: d(2026, 1, 1)),
          []);
      expect(fire(Frequency(FreqRule.daily), d(2026, 1, 1), count: 0), []);
    });
  });

  group('phrases', () {
    final s = d(2026, 10, 8);
    test('full', () {
      expect(describeFrequency(Frequency.once, s), 'Once on 8 Oct 2026');
      expect(describeFrequency(Frequency(FreqRule.daily), s), 'Every day');
      expect(describeFrequency(Frequency(FreqRule.weekly), s), 'Every week');
      expect(describeFrequency(Frequency(FreqRule.weekly, days: [2, 1]), s),
          'Every week on Mon, Tue');
      expect(
          describeFrequency(
              Frequency(FreqRule.everyNWeeks, interval: 2, days: [1, 3]), s),
          'Every 2 weeks on Mon, Wed');
      expect(describeFrequency(Frequency(FreqRule.monthly), s), 'Monthly');
      expect(describeFrequency(Frequency(FreqRule.monthly, days: [15, 1]), s),
          'Monthly on the 1st and 15th');
      expect(
          describeFrequency(
              Frequency(FreqRule.everyNMonths, interval: 3, days: [31]), s),
          'Every 3 months on the 31st (last day when short)');
      expect(describeFrequency(Frequency(FreqRule.monthly, days: [1, 2, 3]), s),
          'Monthly on the 1st, 2nd and 3rd');
      expect(
          describeFrequency(Frequency(FreqRule.everyNMonths, interval: 12), s),
          'Yearly');
      expect(
          describeFrequency(Frequency(FreqRule.everyNMonths, interval: 24), s),
          'Every 2 years');
    });
    test('compact', () {
      expect(describeFrequency(Frequency.once, s, compact: true), 'Once');
      expect(
          describeFrequency(Frequency(FreqRule.monthly, days: [31]), s,
              compact: true),
          'Monthly on the 31st');
    });
    test('ordinals', () {
      expect([
        for (final n in [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31]) ordinalDay(n)
      ], [
        '1st',
        '2nd',
        '3rd',
        '4th',
        '11th',
        '12th',
        '13th',
        '21st',
        '22nd',
        '23rd',
        '31st'
      ]);
    });
  });
}
