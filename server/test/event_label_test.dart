// Optional event label (migration 033): nullable text, trim / empty → null,
// max 60 characters; create, patch, list, transfer mirror, import.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/domain/models.dart';
import 'package:budget_server/repo/stream_repo.dart';
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

  const email = 'event-label-test@example.com';
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

  test('parseEventLabel trims, empty is null, and caps length at 60', () {
    expect(parseEventLabel(null), isNull);
    expect(parseEventLabel(''), isNull);
    expect(parseEventLabel('   '), isNull);
    expect(parseEventLabel('  Bonus  '), 'Bonus');
    expect(parseEventLabel('x' * 60), 'x' * 60);
    expect(() => parseEventLabel('x' * 61), throwsFormatException);
    expect(() => parseEventLabel(12), throwsFormatException);
  });

  test('migration 033: nullable label column, length 1–60', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final col = await c.execute(
        "SELECT is_nullable, data_type FROM information_schema.columns "
        "WHERE table_name = 'events' AND column_name = 'label'");
    expect(col.single, ['YES', 'text']);
    final ck = await c.execute(
        "SELECT 1 FROM pg_constraint WHERE conname = 'events_label_ck'");
    expect(ck, isNotEmpty);
  });

  test('label over the API: create, list, patch, clear, transfer, import',
      () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final a = await stream(c, owner, 'Label A');
      final b = await stream(c, owner, 'Label B');
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;

      final plain = await call(streams, 'POST', '/$a/events', {
        'direction': 'debit',
        'amount': '5',
        'startDate': '2026-10-05',
      });
      expect(plain.status, 201, reason: '${plain.json}');
      expect(plain.json['label'], isNull);

      final made = await call(streams, 'POST', '/$a/events', {
        'name': 'Salary',
        'label': '  Bonus  ',
        'direction': 'credit',
        'amount': '100',
        'startDate': '2026-10-05',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'transferToStreamId': b,
      });
      expect(made.status, 201, reason: '${made.json}');
      expect(made.json['label'], 'Bonus');
      final id = made.json['id'] as String;
      final peer = made.json['transfer']['peerEventId'] as String;
      expect((await call(events, 'GET', '/$peer')).json['label'], 'Bonus',
          reason: 'transfers share the label');

      final list =
          (await call(streams, 'GET', '/$a/events')).json['events'] as List;
      final row = list.firstWhere((e) => e['id'] == id);
      expect(row['label'], 'Bonus');

      // A patch without `label` keeps it; empty / null clears both sides.
      final renamed = await call(events, 'PATCH', '/$id', {'name': 'Pay'});
      expect(renamed.json['label'], 'Bonus');
      final cleared = await call(events, 'PATCH', '/$id', {'label': '  '});
      expect(cleared.status, 200, reason: '${cleared.json}');
      expect(cleared.json['label'], isNull);
      expect((await call(events, 'GET', '/$peer')).json['label'], isNull);

      final set = await call(events, 'PATCH', '/$id', {'label': 'Overtime'});
      expect(set.json['label'], 'Overtime');
      expect((await call(events, 'GET', '/$peer')).json['label'], 'Overtime');

      expect((await call(events, 'PATCH', '/$id', {'label': 'x' * 61})).status,
          400);

      // Import: label is passed through; absent is null.
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
              'label': 'Imported',
            },
            {
              'name': 'I2',
              'direction': 'debit',
              'amount': '1',
              'startOffset': 2,
              'recurrence': {'mode': 'once'},
            },
          ]));
      expect(imp.status, anyOf(200, 201), reason: '${imp.json}');
      final after =
          (await call(streams, 'GET', '/$a/events')).json['events'] as List;
      final byName = {for (final e in after) e['name']: e['label']};
      expect(byName['I1'], 'Imported');
      expect(byName['I2'], isNull);

      final badImp = await call(
          streams,
          'POST',
          '/$a/events/import?dryRun=true&root=2026-10-01',
          jsonEncode([
            {
              'name': 'Bad',
              'direction': 'debit',
              'amount': '1',
              'startOffset': 1,
              'recurrence': {'mode': 'once'},
              'label': 'x' * 61,
            },
          ]));
      expect(badImp.status, 400);
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
