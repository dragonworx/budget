// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/accounts.dart';
import 'package:budget_server/api/transactions.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/account_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'helpers.dart';
import 'package:test/test.dart';

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

  Future<dynamic> call(Handler h, String method, String path,
      [Object? body]) async {
    final res = await h(Request(method, Uri.parse('http://x$path'),
        body: body == null ? null : jsonEncode(body)));
    final text = await res.readAsString();
    return (
      status: res.statusCode,
      json: text.isEmpty ? null : jsonDecode(text)
    );
  }

  test('transfer pair: create, mirror edits/skips, seed shift, delete both',
      () async {
    final c = conn;
    if (c == null) {
      markTestSkipped('no test database');
      return;
    }
    final owner = await testOwnerId(c);
    final made = <String>[];
    try {
      Future<String> acct(String name) async {
        await c.execute(
            Sql.named('DELETE FROM accounts WHERE owner_id = @o::uuid '
                'AND name = @n'),
            parameters: {'o': owner, 'n': name});
        final id = (await AccountRepo(c).create(
                ownerId: owner,
                name: name,
                seedBalance: Decimal.zero,
                seedDate: DateTime.utc(2026, 10, 1),
                lossThreshold: Decimal.zero))
            .id;
        made.add(id);
        return id;
      }

      final a = await acct('A');
      final b = await acct('B');
      final accounts = buildAccountsApi(c).call;
      final txs = transactionsRouter(c).call;

      // Self-transfer rejected, nothing written.
      final bad = await call(accounts, 'POST', '/$a/transactions', {
        'direction': 'debit',
        'amount': '10',
        'startDate': '2026-10-05',
        'transferToAccountId': a,
      });
      expect(bad.status, 400);
      expect(
          (await call(accounts, 'GET', '/$a/transactions'))
              .json['transactions'],
          isEmpty);

      final created = await call(accounts, 'POST', '/$a/transactions', {
        'name': 'Savings',
        'direction': 'debit',
        'amount': '10',
        'startDate': '2026-10-05',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
        'endMode': 'until_date',
        'endDate': '2026-11-30',
        'transferToAccountId': b,
      });
      expect(created.status, 201);
      final src = created.json;
      expect(src['transfer']['peerAccountId'], b);
      expect(src['transfer']['peerAccountName'], 'B');
      expect(src['transfer'].containsKey('peerProjectName'), isFalse);
      final peerId = src['transfer']['peerTransactionId'] as String;

      final bList = (await call(accounts, 'GET', '/$b/transactions'))
          .json['transactions'] as List;
      expect(bList, hasLength(1));
      expect(bList.first['id'], peerId);
      expect(bList.first['direction'], 'credit');
      expect(bList.first['amount'], '10');
      expect(bList.first['endDate'], '2026-11-30');
      expect(bList.first['transfer']['peerAccountId'], a);

      // B's balance gets +10 on the transfer date.
      final bal = await call(
          accounts, 'GET', '/$b/balance?from=2026-10-05&to=2026-10-05');
      expect(jsonEncode(bal.json), contains('"10"'));

      // Edit the destination side: source mirrors with inverted sign.
      final edited = await call(txs, 'PATCH', '/$peerId',
          {'amount': '25', 'startDate': '2026-10-06', 'name': 'Save'});
      expect(edited.status, 200);
      final srcNow = (await call(txs, 'GET', '/${src['id']}')).json;
      expect(srcNow['amount'], '25');
      expect(srcNow['direction'], 'debit');
      expect(srcNow['startDate'], '2026-10-06');
      expect(srcNow['name'], 'Save');

      // Skips mirror both ways.
      await call(
          txs, 'PUT', '/${src['id']}/skips/2026-10-13', {'skipped': true});
      final skips = await c.execute(
          Sql.named(
              'SELECT count(*) FROM skipped_occurrences WHERE transaction_id = @p::uuid'),
          parameters: {'p': peerId});
      expect(skips.first[0], 1);

      // Seed shift of A moves the pair together (+3 days).
      await call(accounts, 'PATCH', '/$a', {'seedDate': '2026-10-04'});
      final peerNow = (await call(txs, 'GET', '/$peerId')).json;
      expect(peerNow['startDate'], '2026-10-09');
      expect(peerNow['endDate'], '2026-12-03');
      final peerSkip = await c.execute(
          Sql.named(
              'SELECT date::text FROM skipped_occurrences WHERE transaction_id = @p::uuid'),
          parameters: {'p': peerId});
      expect(peerSkip.first[0], '2026-10-16');

      // Deleting one side removes both.
      expect((await call(txs, 'DELETE', '/$peerId')).status, 204);
      expect((await call(txs, 'GET', '/${src['id']}')).status, 404);
      expect(
          (await call(accounts, 'GET', '/$a/transactions'))
              .json['transactions'],
          isEmpty);

      // Deleting an account turns the surviving side into a plain row.
      final again = (await call(accounts, 'POST', '/$a/transactions', {
        'direction': 'debit',
        'amount': '5',
        'startDate': '2026-10-05',
        'transferToAccountId': b,
        'skippedDates': [],
      }))
          .json;
      await AccountRepo(c).delete(b);
      final left = (await call(txs, 'GET', '/${again['id']}')).json;
      expect(left['transfer'], isNull);
    } finally {
      for (final id in made) {
        await c.execute(Sql.named('DELETE FROM accounts WHERE id = @a::uuid'),
            parameters: {'a': id});
      }
    }
  });
}
