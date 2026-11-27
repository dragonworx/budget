// POST /api/events/:id/move — move a transaction to another stream,
// keeping calendar dates, rejecting transfers.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/event_repo.dart';
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

  const email = 'event-move-test@example.com';
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

  Future<String> stream(Session c, String owner, String name,
          {DateTime? seed}) async =>
      (await StreamRepo(c).create(
              ownerId: owner,
              name: name,
              seedBalance: Decimal.zero,
              seedDate: seed ?? DateTime.utc(2026, 10, 1),
              lossThreshold: Decimal.zero))
          .id;

  test('moving keeps the calendar date and leaves the series intact', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final fromId = await stream(c, owner, 'Wages');
      final toId = await stream(c, owner, 'Savings',
          seed: DateTime.utc(2026, 1, 1));
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;
      final made = await call(streams, 'POST', '/$fromId/events', {
        'name': 'Rent',
        'direction': 'debit',
        'amount': '1100',
        'startDate': '2026-10-15',
        'recurrenceMode': 'every',
        'interval': 2,
        'unit': 'weeks',
      });
      expect(made.status, 201, reason: '${made.json}');
      final id = made.json['id'] as String;
      final r = await call(events, 'POST', '/$id/move', {'streamId': toId});
      expect(r.status, 200, reason: '${r.json}');
      expect(r.json['streamId'], toId);
      expect(r.json['startDate'], '2026-10-15');
      expect(r.json['amount'], '1100');
      expect(r.json['name'], 'Rent');
      expect(r.json['fromStreamId'], fromId);
      expect(r.json['toStreamId'], toId);
      expect(r.json['recurrenceMode'], 'every');
      final moved = await EventRepo(c).get(id);
      expect(moved!.streamId, toId);
      expect(moved.startDate, DateTime.utc(2026, 10, 15));
      final fromList = await EventRepo(c).listByStream(fromId);
      final toList = await EventRepo(c).listByStream(toId);
      expect(fromList.map((e) => e.id), isNot(contains(id)));
      expect(toList.map((e) => e.id), contains(id));
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });

  test('a transfer is rejected', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final fromId = await stream(c, owner, 'Wages');
      final toId = await stream(c, owner, 'Savings');
      final peerId = await stream(c, owner, 'Mortgage');
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;
      final made = await call(streams, 'POST', '/$fromId/events', {
        'name': 'To Mortgage',
        'direction': 'debit',
        'amount': '695',
        'startDate': '2026-11-02',
        'transferToStreamId': peerId,
      });
      expect(made.status, 201, reason: '${made.json}');
      final id = made.json['id'] as String;
      final r = await call(events, 'POST', '/$id/move', {'streamId': toId});
      expect(r.status, 400, reason: '${r.json}');
      expect(r.json['error'].toString().toLowerCase(), contains('transfer'));
      expect((await EventRepo(c).get(id))!.streamId, fromId);
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
