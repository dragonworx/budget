// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
//
// Per-event colour (migration 021) and the day pick's "end every event on
// this day" batch with its Undo (migration 022).
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/enums.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:budget_server/repo/trim_batch_repo.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  Connection? conn;
  setUpAll(() async {
    final url = Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://budget:budget@127.0.0.1:5432/budget_test';
    try {
      conn = await openConnection(Config(databaseUrl: url, host: '', port: 0));
      await applyMigrations(conn!, migrationsDir: 'migrations');
    } catch (_) {
      conn = null;
    }
  });
  tearDownAll(() async => conn?.close());

  const email = 'event-colour-trim-test@example.com';
  User? user;
  Future<({int status, dynamic json})> call(
      Handler h, String method, String path,
      [Object? body]) async {
    final res = await h(Request(method, Uri.parse('http://x$path'),
        context: {if (user != null) 'auth': AuthContext(user!, 't')},
        body: body == null ? null : jsonEncode(body)));
    final text = await res.readAsString();
    return (
      status: res.statusCode,
      json: text.isEmpty ? null : jsonDecode(text)
    );
  }

  Future<String> stream(Session c, String owner, String name) async =>
      (await StreamRepo(c).create(
              ownerId: owner,
              name: name,
              seedBalance: Decimal.zero,
              seedDate: DateTime.utc(2026, 10, 1),
              lossThreshold: Decimal.zero))
          .id;

  test('parseEventColor normalises #RRGGBB and rejects anything else', () {
    expect(parseEventColor('#abcdef'), '#ABCDEF');
    expect(parseEventColor('12ab9F'), '#12AB9F');
    expect(parseEventColor(null), isNull);
    expect(parseEventColor(''), isNull);
    for (final bad in ['red', '#abc', '#ABCDEFF', 12, '#GG0000']) {
      expect(() => parseEventColor(bad), throwsFormatException, reason: '$bad');
    }
  });

  test('migration 021: nullable colour column, uppercase hex only', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final col = await c.execute(
        "SELECT is_nullable, data_type FROM information_schema.columns "
        "WHERE table_name = 'events' AND column_name = 'color'");
    expect(col.single, ['YES', 'text']);
    final owner = await testOwnerId(c, email);
    try {
      final a = await stream(c, owner, 'Colour check');
      Future<void> insert(String? color) => c.execute(Sql.named('''
            INSERT INTO events (id, stream_id, name, direction, amount,
              start_date, recurrence_mode, end_mode, color)
            VALUES (gen_random_uuid(), @a::uuid, 'x', 'debit', 1,
              '2026-10-01', 'once', 'never', @c)
          '''), parameters: {'a': a, 'c': color});
      await insert(null);
      await insert('#1E88E5');
      for (final bad in ['#1e88e5', 'blue', '#12345']) {
        await expectLater(insert(bad), throwsA(isA<ServerException>()),
            reason: bad);
      }
      // 022's table exists and is empty for the stream.
      expect(
          (await c.execute(
                  Sql.named(
                      'SELECT count(*) FROM event_trim_batches WHERE stream_id = @a::uuid'),
                  parameters: {'a': a}))
              .first[0],
          0);
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });

  test('colour over the API: create, patch, clear, transfer mirror, import',
      () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final a = await stream(c, owner, 'Colour A');
      final b = await stream(c, owner, 'Colour B');
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;

      final plain = await call(streams, 'POST', '/$a/events', {
        'direction': 'debit',
        'amount': '5',
        'startDate': '2026-10-05',
      });
      expect(plain.status, 201);
      expect(plain.json['name'], 'Untitled');
      expect(plain.json['color'], '#3D6FD8',
          reason: 'a new category takes the first free palette colour');

      final bad = await call(streams, 'POST', '/$a/events', {
        'direction': 'debit',
        'amount': '5',
        'startDate': '2026-10-05',
        'color': 'purple',
      });
      expect(bad.status, 400);

      final made = await call(streams, 'POST', '/$a/events', {
        'name': 'Save',
        'direction': 'debit',
        'amount': '10',
        'startDate': '2026-10-05',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'color': '8e24aa',
        'transferToStreamId': b,
      });
      expect(made.status, 201);
      expect(made.json['color'], '#8E24AA');
      final id = made.json['id'] as String;
      final peer = made.json['transfer']['peerEventId'] as String;
      expect((await call(events, 'GET', '/$peer')).json['color'], '#8E24AA',
          reason: 'transfers share the colour');

      // A patch without `color` keeps it; with one, both sides change.
      final renamed = await call(events, 'PATCH', '/$id', {'name': 'Saving'});
      expect(renamed.json['color'], '#8E24AA');
      final recolored =
          await call(events, 'PATCH', '/$peer', {'color': '#43A047'});
      expect(recolored.status, 200);
      expect((await call(events, 'GET', '/$id')).json['color'], '#43A047');
      expect(
          (await call(events, 'PATCH', '/$id', {'color': 'nope'})).status, 400);

      // Split from an occurrence: the new series takes the given colour.
      final split = await call(events, 'POST', '/$id/split', {
        'date': '2026-10-19',
        'name': 'Saving more',
        'direction': 'debit',
        'amount': '20',
        'color': '#F4511E',
      });
      expect(split.status, anyOf(200, 201), reason: '${split.json}');
      expect(split.json['created']['color'], '#F4511E');
      expect(split.json['original']['color'], '#43A047',
          reason: 'the earlier part keeps its colour');
      final list =
          (await call(streams, 'GET', '/$a/events')).json['events'] as List;
      final colors = {for (final e in list) e['name']: e['color']};
      expect(colors.values, contains('#F4511E'));

      // Clearing is a no-op now: a category always has a colour.
      final cleared = await call(events, 'PATCH', '/$id', {'color': null});
      expect(cleared.json['color'], '#43A047');
      expect((await call(events, 'GET', '/$peer')).json['color'], '#43A047');

      // Import: `color` and the `colour` alias; bad values are a 400.
      final imp = await call(
          streams,
          'POST',
          '/$a/events/import?root=2026-10-01',
          jsonEncode([
            {
              'name': 'I1',
              'direction': 'debit',
              'amount': '1',
              'startOffset': 1,
              'recurrence': {'mode': 'once'},
              'color': '#00897b',
            },
            {
              'name': 'I2',
              'direction': 'debit',
              'amount': '1',
              'startOffset': 1,
              'recurrence': {'mode': 'once'},
              'colour': 'FDD835',
            },
          ]));
      expect(imp.status, anyOf(200, 201), reason: '${imp.json}');
      final after =
          (await call(streams, 'GET', '/$a/events')).json['events'] as List;
      final byName = {for (final e in after) e['name']: e['color']};
      expect(byName['I1'], '#00897B');
      expect(byName['I2'], '#FDD835');
      final badImp = await call(
          streams,
          'POST',
          '/$a/events/import?dryRun=true&root=2026-10-01',
          jsonEncode([
            {
              'direction': 'debit',
              'amount': '1',
              'startOffset': 1,
              'recurrence': {'mode': 'once'},
              'color': 'teal',
            }
          ]));
      expect(badImp.status, 400);
      expect(jsonEncode(badImp.json), contains('RRGGBB'));
    } finally {
      user = null;
      await deleteOwnedStreams(c, owner);
    }
  });

  test('endOnDayPlan: what ending every event on a day does', () {
    BudgetEvent ev(
            {DateTime? start,
            RecurrenceMode mode = RecurrenceMode.every,
            EndMode end = EndMode.never,
            DateTime? endDate,
            int? count,
            bool enabled = true}) =>
        BudgetEvent(
          id: 'x',
          streamId: 's',
          name: 'n',
          direction: Direction.debit,
          amount: Decimal.one,
          startDate: start ?? DateTime.utc(2026, 10, 1),
          recurrenceMode: mode,
          interval: mode == RecurrenceMode.every ? 1 : null,
          unit: mode == RecurrenceMode.every ? RecurrenceUnit.months : null,
          endMode: end,
          endDate: endDate,
          occurrenceCount: count,
          enabled: enabled,
          createdAt: DateTime.utc(2026),
        );
    final d = DateTime.utc(2026, 11, 10);
    expect(endOnDayPlan(ev(), d), EndOnDay.end);
    expect(endOnDayPlan(ev(start: DateTime.utc(2026, 11, 10)), d), EndOnDay.end,
        reason: 'starts on the day: keeps that occurrence only');
    expect(endOnDayPlan(ev(start: DateTime.utc(2026, 11, 11)), d),
        EndOnDay.delete);
    expect(endOnDayPlan(ev(mode: RecurrenceMode.once), d), isNull);
    expect(
        endOnDayPlan(
            ev(mode: RecurrenceMode.once, start: DateTime.utc(2026, 12)), d),
        EndOnDay.delete);
    expect(
        endOnDayPlan(
            ev(end: EndMode.untilDate, endDate: DateTime.utc(2026, 11, 10)), d),
        isNull,
        reason: 'already ends on the day');
    expect(
        endOnDayPlan(
            ev(end: EndMode.untilDate, endDate: DateTime.utc(2026, 11, 11)), d),
        EndOnDay.end);
    expect(endOnDayPlan(ev(end: EndMode.count, count: 2), d), isNull,
        reason: 'Oct 1, Nov 1: nothing after the day');
    expect(endOnDayPlan(ev(end: EndMode.count, count: 3), d), EndOnDay.end);
    expect(endOnDayPlan(ev(enabled: false), d), isNull);
  });

  test('trim batch: ends / deletes atomically, both transfer sides, undo',
      () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    final other = await testOwnerId(c, 'event-trim-other@example.com');
    try {
      final a = await stream(c, owner, 'Trim A');
      final b = await stream(c, owner, 'Trim B');
      final foreign = await stream(c, other, 'Not mine');
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;
      Future<String> add(Map<String, Object?> body, [String? into]) async {
        final r = await call(streams, 'POST', '/${into ?? a}/events',
            {'direction': 'debit', 'amount': '1', ...body});
        expect(r.status, 201, reason: '${r.json}');
        return r.json['id'] as String;
      }

      const weekly = {
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks'
      };
      final open =
          await add({'name': 'Open', 'startDate': '2026-10-06', ...weekly});
      final earlyOnce = await add({'name': 'Early', 'startDate': '2026-10-20'});
      final lateOnce = await add({'name': 'Late', 'startDate': '2026-12-01'});
      final ended = await add({
        'name': 'Ended',
        'startDate': '2026-10-01',
        ...weekly,
        'endMode': 'until_date',
        'endDate': '2026-10-31',
      });
      final counted = await add({
        'name': 'Counted',
        'startDate': '2026-10-01',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'months',
        'endMode': 'count',
        'occurrenceCount': 3,
      });
      final off = await add({
        'name': 'Off',
        'startDate': '2026-10-01',
        ...weekly,
        'enabled': false
      });
      final lateSeries = await add(
          {'name': 'Later series', 'startDate': '2026-11-20', ...weekly});
      final xfer = await add({
        'name': 'To B',
        'startDate': '2026-10-06',
        ...weekly,
        'transferToStreamId': b,
      });
      final xferPeer = (await call(events, 'GET', '/$xfer')).json['transfer']
          ['peerEventId'] as String;
      final lateXfer = await add({
        'name': 'Late to B',
        'startDate': '2026-12-02',
        'transferToStreamId': b,
      });
      final lateXferPeer = (await call(events, 'GET', '/$lateXfer'))
          .json['transfer']['peerEventId'] as String;
      // A transfer into a stream I can't edit (made directly: the API
      // would refuse it).
      final blocked = await add({
        'name': 'To foreign',
        'startDate': '2026-10-06',
        ...weekly,
        'transferToStreamId': foreign,
      });
      // Overrides / skips after the day are pruned, and come back on undo.
      expect(
          (await call(events, 'PUT', '/$open/overrides/2026-11-17',
                  {'amount': '9', 'direction': 'debit'}))
              .status,
          200);
      expect(
          (await call(events, 'PUT', '/$lateSeries/skips/2026-11-27',
                  {'skipped': true}))
              .status,
          200);
      final orderBefore = (await call(streams, 'GET', '/$a/events'))
          .json['events']
          .map((e) => e['id'])
          .toList();

      expect(
          (await call(streams, 'POST', '/$a/events/trim', {'date': 'x'}))
              .status,
          400);
      final r = await call(
          streams, 'POST', '/$a/events/trim', {'date': '2026-11-10'});
      expect(r.status, 200, reason: '${r.json}');
      expect(r.json['date'], '2026-11-10');
      expect(r.json['batchId'], isA<String>());
      expect(Set.of(r.json['ended']), {open, counted, xfer});
      expect(Set.of(r.json['deleted']), {lateOnce, lateSeries, lateXfer});
      expect(r.json['blocked'], [blocked]);

      Future<Map<String, dynamic>?> get(String id) async {
        final g = await call(events, 'GET', '/$id');
        return g.status == 404 ? null : g.json as Map<String, dynamic>;
      }

      for (final id in [open, counted, xfer, xferPeer]) {
        final e = (await get(id))!;
        expect(e['endMode'], 'until_date', reason: e['name']);
        expect(e['endDate'], '2026-11-10', reason: e['name']);
        expect(e['occurrenceCount'], isNull);
      }
      expect((await get(open))!['overrides'], isEmpty);
      for (final id in [lateOnce, lateSeries, lateXfer, lateXferPeer]) {
        expect(await get(id), isNull, reason: id);
      }
      for (final id in [earlyOnce, ended, off, blocked]) {
        expect(
            (await get(id))!['endDate'], id == ended ? '2026-10-31' : isNull);
      }

      // Nothing left to do: no batch.
      final again = await call(
          streams, 'POST', '/$a/events/trim', {'date': '2026-11-10'});
      expect(again.json['batchId'], isNull);
      expect(again.json['ended'], isEmpty);

      // Only someone else's batch, or a bad id: 404 / 400.
      expect(
          (await call(streams, 'POST', '/$b/events/trim/undo',
                  {'batchId': r.json['batchId']}))
              .status,
          404);
      expect(
          (await call(
                  streams, 'POST', '/$a/events/trim/undo', {'batchId': 'nope'}))
              .status,
          400);

      final u = await call(streams, 'POST', '/$a/events/trim/undo',
          {'batchId': r.json['batchId']});
      expect(u.status, 200, reason: '${u.json}');
      expect((await get(open))!['endMode'], 'never');
      expect((await get(open))!['overrides'], hasLength(1));
      expect((await get(counted))!['endMode'], 'count');
      expect((await get(counted))!['occurrenceCount'], 3);
      expect((await get(xferPeer))!['endMode'], 'never');
      expect((await get(lateXferPeer))!['transfer']['peerEventId'], lateXfer);
      expect((await get(lateSeries))!['name'], 'Later series');
      final skips = await c.execute(
          Sql.named('SELECT count(*) FROM skipped_occurrences '
              'WHERE event_id = @t::uuid'),
          parameters: {'t': lateSeries});
      expect(skips.first[0], 1);
      final orderAfter = (await call(streams, 'GET', '/$a/events'))
          .json['events']
          .map((e) => e['id'])
          .toList();
      expect(orderAfter, orderBefore, reason: 'list positions restored');

      // One undo only.
      expect(
          (await call(streams, 'POST', '/$a/events/trim/undo',
                  {'batchId': r.json['batchId']}))
              .status,
          404);

      // `ids` restricts the batch to the confirmed list.
      final only = await call(streams, 'POST', '/$a/events/trim', {
        'date': '2026-11-10',
        'ids': [open]
      });
      expect(only.json['ended'], [open]);
      expect(only.json['deleted'], isEmpty);
      expect(
          (await call(streams, 'POST', '/$a/events/trim', {
            'date': '2026-11-10',
            'ids': ['x']
          }))
              .status,
          400);

      // Old batches are purged (their Undo is long gone).
      await c.execute(
          Sql.named('UPDATE event_trim_batches '
              "SET created_at = now() - interval '2 days' WHERE stream_id = @a::uuid"),
          parameters: {'a': a});
      expect(await TrimBatchRepo(c).purgeOld(), greaterThanOrEqualTo(1));
      expect(
          (await call(streams, 'POST', '/$a/events/trim/undo',
                  {'batchId': only.json['batchId']}))
              .status,
          404);
    } finally {
      user = null;
      await deleteOwnedStreams(c, owner);
      await deleteOwnedStreams(c, other);
    }
  });
}
