// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/streams.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/engine/calendar_math.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'helpers.dart';
import 'package:test/test.dart';

void main() {
  test('calendarDayDelta is whole days across DST', () {
    expect(calendarDayDelta(DateTime(2026, 10, 1), DateTime(2026, 10, 8)), 7);
    expect(calendarDayDelta(DateTime(2026, 4, 10), DateTime(2026, 4, 1)), -9);
  });

  Connection? conn;
  setUpAll(() async {
    final url = Platform.environment['TEST_DATABASE_URL'] ??
        'postgres://budget:budget@127.0.0.1:5432/budget_test';
    try {
      conn = await openConnection(
        Config(databaseUrl: url, host: '', port: 0),
      );
      await applyMigrations(conn!, migrationsDir: 'migrations');
    } catch (_) {
      conn = null;
    }
  });
  tearDownAll(() async => conn?.close());

  test('changing the seed date shifts schedules, ends and skipped dates',
      () async {
    final c = conn;
    if (c == null) {
      markTestSkipped('no test database');
      return;
    }
    final owner = await testOwnerId(c, 'seed-shift-test@example.com');
    await deleteOwnedStreams(c, owner);
    try {
      final stream = await StreamRepo(c).create(
        ownerId: owner,
        name: 'A',
        seedBalance: Decimal.zero,
        seedDate: DateTime.utc(2026, 10, 16),
        lossThreshold: Decimal.zero,
      );
      final t = await c.execute(
        Sql.named('''
          INSERT INTO events (id, stream_id, name, direction, amount,
            start_date, recurrence_mode, interval, unit, end_mode, end_date)
          VALUES (gen_random_uuid(), @a, 'Rent', 'debit', 100, '2026-10-20',
            'every', 1, 'weeks', 'until_date', '2026-12-01')
          RETURNING id::text
        '''),
        parameters: {'a': stream.id},
      );
      final tid = t.first[0] as String;
      for (final d in ['2026-10-27', '2026-11-03']) {
        await c.execute(
          Sql.named(
            "INSERT INTO skipped_occurrences VALUES (@t::uuid, @d::date)",
          ),
          parameters: {'t': tid, 'd': d},
        );
      }
      final api = buildStreamsApi(c);
      final res = await api.call(Request(
        'PATCH',
        Uri.parse('http://x/${stream.id}'),
        body: jsonEncode({'seedDate': '2026-10-23'}),
      ));
      expect(res.statusCode, 200);
      final row = await c.execute(
        Sql.named(
          'SELECT start_date::text, end_date::text FROM events WHERE id = @t::uuid',
        ),
        parameters: {'t': tid},
      );
      expect(row.first[0], '2026-10-27');
      expect(row.first[1], '2026-12-08');
      final skipped = await c.execute(
        Sql.named(
          'SELECT date::text FROM skipped_occurrences WHERE event_id = @t::uuid ORDER BY date',
        ),
        parameters: {'t': tid},
      );
      // Overlapping shift (10-27 -> 11-03 while 11-03 exists) is safe.
      expect(skipped.map((r) => r[0]), ['2026-11-03', '2026-11-10']);
      // A patch without seedDate moves nothing.
      await api.call(Request(
        'PATCH',
        Uri.parse('http://x/${stream.id}'),
        body: jsonEncode({'name': 'B'}),
      ));
      final again = await c.execute(
        Sql.named('SELECT start_date::text FROM events WHERE id = @t::uuid'),
        parameters: {'t': tid},
      );
      expect(again.first[0], '2026-10-27');
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
