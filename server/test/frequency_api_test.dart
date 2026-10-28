// Structured frequency through the API: create / patch / split / transfer
// / import / balance with rule + days, validation errors (400), the legacy
// cadence fields still accepted, and the shared golden vectors replayed
// through the server's event model. DB-backed parts run against
// TEST_DATABASE_URL (default local budget_test); skipped without Postgres.
import 'dart:convert';
import 'dart:io';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/event_import.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/occurrence_gen.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:budget_server/repo/trim_batch_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

DateTime _p(String s) {
  final x = s.split('-').map(int.parse).toList();
  return DateTime.utc(x[0], x[1], x[2]);
}

String _f(DateTime d) => formatDate(d);

BudgetEvent _event(Frequency f, DateTime start,
        {DateTime? until, int? count}) =>
    BudgetEvent(
      id: 'g',
      streamId: 's',
      name: 'g',
      direction: Direction.debit,
      amount: Decimal.one,
      startDate: start,
      recurrenceMode: f.repeats ? RecurrenceMode.every : RecurrenceMode.once,
      interval: f.legacyInterval,
      unit: f.repeats ? RecurrenceUnit.parse(f.legacyUnit!) : null,
      days: f.days,
      endMode: until != null
          ? EndMode.untilDate
          : count != null
              ? EndMode.count
              : EndMode.never,
      endDate: until,
      occurrenceCount: count,
      enabled: true,
      createdAt: DateTime.utc(2026),
    );

void main() {
  test(
      'golden vectors: the server event model fires exactly like the '
      'shared engine (the client replays the same file)', () {
    final cases = jsonDecode(
        File('packages/budget_recurrence/test/golden_vectors.json')
            .readAsStringSync()) as List;
    expect(cases.length, greaterThan(150));
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final f = Frequency.fromJson(c['frequency'] as Map<String, dynamic>);
      final e = _event(f, _p(c['start'] as String),
          until: c['until'] == null ? null : _p(c['until'] as String),
          count: c['count'] as int?);
      // A one-off never has an end in the model.
      final dates = OccurrenceGenerator.datesForEvent(
          f.repeats ? e : _event(f, e.startDate),
          _p(c['from'] as String),
          _p(c['to'] as String));
      expect([for (final d in dates) _f(d)], c['dates'],
          reason: '${c['frequency']} from ${c['start']}');
      // The JSON the API sends carries the rule.
      expect(e.toJson()['frequency'], f.toJson());
    }
  });

  test('trim: a rule whose first firing is after the day is deleted', () {
    final f = Frequency(FreqRule.weekly, days: [1, 2]);
    // Thu 8 Oct 2026 start, first fires Mon 12 Oct.
    final e = _event(f, DateTime.utc(2026, 10, 8));
    expect(endOnDayPlan(e, DateTime.utc(2026, 10, 10)), EndOnDay.delete);
    expect(endOnDayPlan(e, DateTime.utc(2026, 10, 12)), EndOnDay.end);
  });

  test('import accepts the structured rule and the original cadence', () {
    final root = DateTime.utc(2026, 10, 8);
    final items = parseImport(
        jsonEncode([
          {
            'name': 'Mon Tue',
            'direction': 'debit',
            'amount': 5,
            'startOffset': 0,
            'recurrence': {
              'rule': 'weekly',
              'days': [2, 1, 1]
            },
            'end': {'mode': 'never'},
          },
          {
            'name': 'Old fortnightly',
            'direction': 'debit',
            'amount': 5,
            'startOffset': 0,
            'recurrence': {'mode': 'every', 'interval': 2, 'unit': 'weeks'},
            'end': {'mode': 'never'},
          },
          {
            'name': 'Old yearly',
            'direction': 'credit',
            'amount': 5,
            'startOffset': 0,
            'recurrence': {'mode': 'every', 'interval': 1, 'unit': 'years'},
            'end': {'mode': 'count', 'occurrences': 3},
          },
          {
            'name': 'Cadence + days',
            'direction': 'credit',
            'amount': 5,
            'startOffset': 0,
            'recurrence': {
              'mode': 'every',
              'interval': 3,
              'unit': 'months',
              'days': [31]
            },
            'end': {'mode': 'never'},
          },
          {
            'name': 'Once',
            'direction': 'credit',
            'amount': 5,
            'startOffset': 2,
            'recurrence': {'rule': 'once'},
          },
        ]),
        root: root);
    expect(items[0].unit, RecurrenceUnit.weeks);
    expect(items[0].interval, 1);
    expect(items[0].days, [1, 2]);
    // The preview echoes the structured rule (the client shows its phrase).
    expect(items[0].toJson()['frequency'], {
      'rule': 'weekly',
      'interval': 1,
      'days': [1, 2]
    });
    expect(items[1].interval, 2);
    expect(items[1].days, isEmpty);
    // Years are stored as 12·N months (the same dates).
    expect(items[2].unit, RecurrenceUnit.months);
    expect(items[2].interval, 12);
    expect(items[3].days, [31]);
    expect(items[4].recurrenceMode, RecurrenceMode.once);

    Never fails(Object rec) {
      try {
        parseImport(
            jsonEncode([
              {
                'direction': 'debit',
                'amount': 1,
                'startOffset': 0,
                'recurrence': rec,
                'end': {'mode': 'never'},
              }
            ]),
            root: root);
      } on ImportValidationException catch (e) {
        throw e.issues.single.field!;
      }
      fail('accepted $rec');
    }

    expect(() => fails({'rule': 'hourly'}), throwsA('recurrence.rule'));
    expect(
        () => fails({
              'rule': 'weekly',
              'days': [8]
            }),
        throwsA('recurrence.days'));
    expect(
        () => fails({
              'rule': 'daily',
              'days': [1]
            }),
        throwsA('recurrence.days'));
    expect(
        () => fails({
              'rule': 'monthly',
              'days': [0]
            }),
        throwsA('recurrence.days'));
    expect(() => fails({'rule': 'every_n_weeks', 'interval': 0}),
        throwsA('recurrence.interval'));
    expect(
        () => fails({
              'mode': 'every',
              'interval': 1,
              'unit': 'days',
              'days': [1]
            }),
        throwsA('recurrence.days'));
  });

  group('API (DB)', () {
    Connection? conn;
    setUpAll(() async {
      final url = Platform.environment['TEST_DATABASE_URL'] ??
          'postgres://budget:budget@127.0.0.1:5432/budget_test';
      try {
        conn =
            await openConnection(Config(databaseUrl: url, host: '', port: 0));
        await applyMigrations(conn!, migrationsDir: 'migrations');
      } catch (_) {
        conn = null;
      }
    });
    tearDownAll(() async => conn?.close());

    Future<({int status, dynamic json})> call(
        Handler h, String method, String path,
        [Object? body]) async {
      final res = await h(Request(method, Uri.parse('http://x$path'),
          body: body == null ? null : jsonEncode(body)));
      final text = await res.readAsString();
      return (
        status: res.statusCode,
        json: text.isEmpty ? null : jsonDecode(text)
      );
    }

    test('create / patch / split / transfer / balance with rule + days',
        () async {
      final c = conn;
      if (c == null) return markTestSkipped('no test database');
      final owner = await testOwnerId(c);
      final made = <String>[];
      try {
        Future<String> stream(String name) async {
          await c.execute(
              Sql.named('DELETE FROM streams WHERE owner_id = @o::uuid '
                  'AND name = @n'),
              parameters: {'o': owner, 'n': name});
          final id = (await StreamRepo(c).create(
                  ownerId: owner,
                  name: name,
                  seedBalance: Decimal.zero,
                  seedDate: DateTime.utc(2026, 10, 1),
                  lossThreshold: Decimal.zero))
              .id;
          made.add(id);
          return id;
        }

        final a = await stream('Freq A');
        final b = await stream('Freq B');
        final streams = buildStreamsApi(c).call;
        final events = eventsRouter(c).call;

        Future<int> status(Map<String, Object?> body) async =>
            (await call(streams, 'POST', '/$a/events', {
              'direction': 'debit',
              'amount': '1',
              'startDate': '2026-10-08',
              'endMode': 'never',
              ...body,
            }))
                .status;
        // Validation.
        expect(
            await status({
              'frequency': {'rule': 'hourly'}
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'weekly',
                'days': [0]
              }
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'weekly',
                'days': [8]
              }
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'monthly',
                'days': [32]
              }
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'daily',
                'days': [1]
              }
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'once',
                'days': [1]
              }
            }),
            400);
        expect(
            await status({
              'frequency': {
                'rule': 'weekly',
                'days': ['Mon']
              }
            }),
            400);
        expect(
            await status({
              'frequency': {'rule': 'every_n_weeks', 'interval': 0}
            }),
            400);
        expect(
            await status({
              'frequency': {'rule': 'weekly', 'interval': 1.5}
            }),
            400);
        expect(await status({'frequency': 'weekly'}), 400);
        expect(
            await status({
              'recurrenceMode': 'every',
              'interval': 1,
              'unit': 'days',
              'days': [1]
            }),
            400);
        expect(
            await status({
              'recurrenceMode': 'once',
              'days': [1]
            }),
            400);
        expect(
            (await call(streams, 'GET', '/$a/events')).json['events'], isEmpty);

        // Weekly Mon, Tue (from a Thursday), sent unsorted with a repeat.
        final w = await call(streams, 'POST', '/$a/events', {
          'name': 'Gym',
          'direction': 'debit',
          'amount': '10',
          'startDate': '2026-10-08',
          'frequency': {
            'rule': 'weekly',
            'days': [2, 1, 2]
          },
          'endMode': 'never',
          'transferToStreamId': b,
        });
        expect(w.status, 201, reason: '${w.json}');
        expect(w.json['frequency'], {
          'rule': 'weekly',
          'interval': 1,
          'days': [1, 2]
        });
        expect(w.json['days'], [1, 2]);
        expect(w.json['recurrenceMode'], 'every');
        expect(w.json['unit'], 'weeks');
        final id = w.json['id'] as String;
        final peer = w.json['transfer']['peerEventId'] as String;
        // The transfer's other row has the same rule.
        final p = await call(events, 'GET', '/$peer');
        expect(p.json['frequency'], w.json['frequency']);

        // The balance fires on Mondays and Tuesdays only.
        final bal = await call(
            streams, 'GET', '/$a/balance?from=2026-10-01&to=2026-10-31');
        expect([
          for (final o in bal.json['occurrences'] as List)
            if (o['eventId'] == id) o['date']
        ], [
          '2026-10-12',
          '2026-10-13',
          '2026-10-19',
          '2026-10-20',
          '2026-10-26',
          '2026-10-27'
        ]);

        // PATCH: every 2 weeks on Mon, Wed, Fri; the peer follows.
        final patched = await call(events, 'PATCH', '/$id', {
          'frequency': {
            'rule': 'every_n_weeks',
            'interval': 2,
            'days': [5, 3, 1]
          },
        });
        expect(patched.status, 200, reason: '${patched.json}');
        expect(patched.json['frequency'], {
          'rule': 'every_n_weeks',
          'interval': 2,
          'days': [1, 3, 5]
        });
        expect((await call(events, 'GET', '/$peer')).json['frequency'],
            patched.json['frequency']);
        // A legacy PATCH (old client) of another field keeps the days.
        final renamed = await call(events, 'PATCH', '/$id', {'name': 'Gym 2'});
        expect(renamed.json['days'], [1, 3, 5]);
        // Bad days on PATCH: 400, nothing changes.
        final bad = await call(events, 'PATCH', '/$id', {
          'frequency': {
            'rule': 'monthly',
            'days': [40]
          }
        });
        expect(bad.status, 400);
        expect((await call(events, 'GET', '/$id')).json['days'], [1, 3, 5]);

        // Split "from now on" at Wed 21 Oct: the new series gets monthly
        // on the 1st and 15th; the original ends the day before.
        final split = await call(events, 'POST', '/$id/split', {
          'date': '2026-10-21',
          'name': 'Gym 3',
          'direction': 'debit',
          'amount': '12',
          'frequency': {
            'rule': 'monthly',
            'days': [15, 1]
          },
        });
        expect(split.status, 200, reason: '${split.json}');
        expect(split.json['original']['endDate'], '2026-10-20');
        expect(split.json['original']['days'], [1, 3, 5]);
        expect(split.json['created']['frequency'], {
          'rule': 'monthly',
          'interval': 1,
          'days': [1, 15]
        });
        expect(split.json['created']['startDate'], '2026-10-21');
        final createdPeer =
            split.json['created']['transfer']['peerEventId'] as String;
        expect((await call(events, 'GET', '/$createdPeer')).json['frequency'],
            split.json['created']['frequency']);
        // A split on a day the rule does not fire is refused.
        final off = await call(events, 'POST', '/$id/split', {
          'date': '2026-10-13',
          'name': 'x',
          'direction': 'debit',
          'amount': '1',
        });
        expect(off.status, 400);

        // Every 3 months on the 31st, until (inclusive).
        final q = await call(streams, 'POST', '/$a/events', {
          'name': 'Quarterly',
          'direction': 'credit',
          'amount': '100',
          'startDate': '2026-11-05',
          'frequency': {
            'rule': 'every_n_months',
            'interval': 3,
            'days': [31]
          },
          'endMode': 'until_date',
          'endDate': '2027-05-31',
        });
        expect(q.status, 201, reason: '${q.json}');
        final qb = await call(
            streams, 'GET', '/$a/balance?from=2026-10-01&to=2028-01-01');
        expect([
          for (final o in qb.json['occurrences'] as List)
            if (o['eventId'] == q.json['id']) o['date']
        ], [
          '2026-11-30',
          '2027-02-28',
          '2027-05-31'
        ]);

        // Legacy fields + days still work, as does the plain cadence.
        final legacy = await call(streams, 'POST', '/$a/events', {
          'name': 'Legacy',
          'direction': 'credit',
          'amount': '1',
          'startDate': '2026-10-08',
          'recurrenceMode': 'every',
          'interval': 1,
          'unit': 'months',
          'days': [1, 15],
          'endMode': 'count',
          'occurrenceCount': 3,
        });
        expect(legacy.status, 201, reason: '${legacy.json}');
        expect(legacy.json['frequency']['rule'], 'monthly');
        expect(legacy.json['days'], [1, 15]);
      } finally {
        for (final s in made) {
          await c.execute(
              Sql.named('DELETE FROM events WHERE stream_id = @s::uuid'),
              parameters: {'s': s});
          await c.execute(Sql.named('DELETE FROM streams WHERE id = @s::uuid'),
              parameters: {'s': s});
        }
      }
    });
  });
}
