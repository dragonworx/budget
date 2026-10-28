// The client reads the shared engine's golden vectors (written by the
// server package, server/packages/budget_recurrence/tool/golden.dart)
// through its own model: the dates the graph / calendar / reminders use
// and the phrases the editor and Events list show are the server's, case
// for case. Also: the client model's JSON (new `frequency` + `days`, the
// old cadence-only format, nested legacy `recurrence`).
import 'dart:convert';
import 'dart:io';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/features/reminders/reminders_model.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _d(String s) => parseDate(s);

String _f(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, dynamic> _eventJson(Map<String, dynamic> c, {bool legacy = false}) {
  final f = Frequency.fromJson(c['frequency'] as Map<String, dynamic>);
  return {
    'id': 'g',
    'streamId': 's',
    'name': 'Golden',
    'direction': 'debit',
    'amount': '10',
    'startDate': c['start'],
    if (legacy) ...{
      'recurrenceMode': f.repeats ? 'every' : 'once',
      'interval': f.legacyInterval,
      'unit': f.legacyUnit,
      'days': f.days,
    } else
      'frequency': c['frequency'],
    'endMode': c['until'] != null
        ? 'until_date'
        : (c['count'] != null ? 'count' : 'never'),
    'endDate': c['until'],
    'occurrenceCount': c['count'],
  };
}

void main() {
  final cases = (jsonDecode(
    File('../server/packages/budget_recurrence/test/golden_vectors.json')
        .readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();

  test('golden vectors: ${cases.length} cases', () {
    expect(cases.length, greaterThanOrEqualTo(150));
  });

  for (final legacy in [false, true]) {
    test('every golden case replays through the client model '
        '(${legacy ? 'legacy cadence + days' : 'structured frequency'} '
        'JSON): dates, phrases, payload', () {
      for (final c in cases) {
        final t = BudgetEvent.fromJson(_eventJson(c, legacy: legacy));
        final f = Frequency.fromJson(c['frequency'] as Map<String, dynamic>);
        final why =
            '${c['frequency']} from ${c['start']} '
            'until ${c['until']} count ${c['count']}';
        expect(t.frequency, f, reason: why);
        final lo = _d(c['from'] as String), hi = _d(c['to'] as String);
        expect(
          [for (final d in occurrenceDatesIn(t, lo, hi)) _f(d)],
          c['dates'],
          reason: why,
        );
        expect(
          [for (final d in occurrenceDatesBetween(t, lo, hi)) _f(d)],
          c['dates'],
          reason: 'reminders: $why',
        );
        // The first firings, as the dots / trim / list hints use them.
        final first = estimateOccurrenceDates(t, maxCount: 3);
        final want = (c['dates'] as List).take(3).toList();
        if (_d(c['from'] as String).isBefore(t.startDate)) {
          expect(
            [for (final d in first) _f(d)].take(want.length).toList(),
            want,
            reason: 'estimate: $why',
          );
        }
        expect(frequencyLabel(t), c['compact'], reason: why);
        expect(
          describeFrequency(t.frequency, toRuleDate(t.startDate)),
          c['phrase'],
          reason: why,
        );
        expect(t.toCreateJson()['frequency'], f.toJson(), reason: why);
        // Round trip through the client's own JSON.
        expect(BudgetEvent.fromJson(t.toJson()).frequency, f, reason: why);
      }
    });
  }

  test('old exports: nested recurrence {mode, interval, unit} and flat '
      'years read as their rule', () {
    final nested = BudgetEvent.fromJson({
      'id': 'a',
      'streamId': 's',
      'name': 'Old',
      'direction': 'credit',
      'amount': '1',
      'startDate': '2026-10-08',
      'recurrence': {'mode': 'every', 'interval': 2, 'unit': 'weeks'},
      'endRule': {'mode': 'never'},
    });
    expect(nested.frequency, Frequency(FreqRule.everyNWeeks, interval: 2));
    expect(frequencyLabel(nested), 'Every 2 weeks');
    final years = BudgetEvent.fromJson({
      'id': 'b',
      'streamId': 's',
      'name': 'Rego',
      'direction': 'debit',
      'amount': '880',
      'startDate': '2026-10-08',
      'recurrenceMode': 'every',
      'interval': 1,
      'unit': 'years',
      'endMode': 'never',
    });
    expect(years.frequency, Frequency(FreqRule.everyNMonths, interval: 12));
    expect(frequencyLabel(years), 'Yearly');
    expect(estimateOccurrenceDates(years, maxCount: 2), [
      DateTime(2026, 10, 8),
      DateTime(2027, 10, 8),
    ]);
  });

  test('a mid-edit misfit (month days on a weekly cadence) drops the days '
      'instead of throwing', () {
    final t = BudgetEvent(
      id: 'x',
      streamId: 's',
      name: 'x',
      direction: EventDirection.debit,
      amount: parseMoney('1'),
      startDate: DateTime(2026, 10, 8),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      days: const [31],
      endMode: EndMode.never,
    );
    expect(t.frequency, Frequency(FreqRule.weekly));
  });
}
