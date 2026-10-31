// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
//
// Loan events (spec 002, migration 026): create / PATCH validation, one
// loan per stream, unsupported operations, import rejection and the trim +
// undo round-trip of the loan terms.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/events.dart';
import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// The spec's advanced example (start 2027-01-15).
Map<String, Object?> advancedLoan() => {
      'v': 1,
      'mode': 'advanced',
      'interestType': 'reducing',
      'termMonths': 360,
      'repaymentFrequency': 'monthly',
      'chargeSchedule': 'monthly',
      'chargeDay': 'anniversary',
      'dayCount': '365',
      'ratePeriods': [
        {
          'from': '2027-01-15',
          'ratePct': '5.89',
          'type': 'fixed',
          'interestOnly': false,
          'offsetApplies': false
        },
        {
          'from': '2029-01-15',
          'ratePct': '6.40',
          'type': 'variable',
          'interestOnly': false,
          'offsetApplies': true
        },
      ],
    };

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

  const email = 'loan-routes-test@example.com';
  User? user;
  Future<({int status, dynamic json})> call(
      Handler h, String method, String path,
      [Object? body]) async {
    final res = await h(Request(method, Uri.parse('http://x$path'),
        context: {if (user != null) 'auth': AuthContext(user!, 't')},
        body: body == null
            ? null
            : body is String
                ? body
                : jsonEncode(body)));
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
              seedDate: DateTime.utc(2027, 1, 1),
              lossThreshold: Decimal.zero))
          .id;

  test('create, patch, unsupported operations, import, trim + undo', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final a = await stream(c, owner, 'Loan A');
      final b = await stream(c, owner, 'Loan B');
      final streams = buildStreamsApi(c).call;
      final events = eventsRouter(c).call;
      Map<String, Object?> loanBody([Map<String, Object?> extra = const {}]) =>
          {
            'name': 'Home loan',
            'kind': 'loan',
            'amount': '600000',
            'startDate': '2027-01-15',
            'loan': advancedLoan(),
            ...extra,
          };

      // Bad creates: 400 each, nothing stored.
      final bad = <Map<String, Object?>>[
        loanBody({'direction': 'credit'}),
        loanBody({'amount': '0'}),
        loanBody({'recurrenceMode': 'every', 'interval': 1, 'unit': 'months'}),
        loanBody({'transferToStreamId': b}),
        loanBody({
          'skippedDates': ['2027-01-15']
        }),
        loanBody({'loan': null}),
        loanBody({'kind': 'mortgage'}),
        loanBody({'startDate': '2027-01-16'}), // ratePeriods[0].from != start
        loanBody({
          'loan': {...advancedLoan(), 'v': 2}
        }),
        loanBody({
          'loan': {...advancedLoan(), 'extra': 1}
        }),
        loanBody({
          'loan': {...advancedLoan(), 'firstRepaymentDate': '2027-03-01'}
        }),
        {
          'direction': 'debit',
          'amount': '1',
          'startDate': '2027-01-15',
          'loan': advancedLoan()
        },
      ];
      for (final body in bad) {
        final r = await call(streams, 'POST', '/$a/events', body);
        expect(r.status, 400, reason: '$body -> ${r.json}');
      }
      final count = await c.execute(
          Sql.named('SELECT count(*) FROM events WHERE stream_id = @a::uuid'),
          parameters: {'a': a});
      expect(count.single[0], 0);

      // A good create: debit, once, defaults filled.
      final r = await call(streams, 'POST', '/$a/events', loanBody());
      expect(r.status, 201, reason: '${r.json}');
      final loanId = r.json['id'] as String;
      expect(r.json['kind'], 'loan');
      expect(r.json['direction'], 'debit');
      expect(r.json['recurrenceMode'], 'once');
      expect(r.json['loan']['firstRepaymentDate'], '2027-02-15');
      expect(r.json['loan']['ratePeriods'][1]['ratePct'], '6.40');

      // A standard event carries kind "standard" and loan null.
      final s = await call(streams, 'POST', '/$a/events', {
        'name': 'Pay',
        'direction': 'credit',
        'amount': '100',
        'startDate': '2027-01-20',
      });
      expect(s.status, 201);
      final std = s.json['id'] as String;
      expect(s.json['kind'], 'standard');
      expect(s.json['loan'], isNull);

      // One loan per stream.
      expect(
          (await call(streams, 'POST', '/$a/events', loanBody())).status, 409);
      final list = await call(streams, 'GET', '/');
      final mine = {
        for (final x in list.json['streams'] as List) x['id']: x['hasLoan'],
      };
      expect(mine[a], true);
      expect(mine[b], false);

      // PATCH rules.
      for (final body in <Map<String, Object?>>[
        {'kind': 'standard'},
        {'direction': 'credit'},
        {'recurrenceMode': 'every', 'interval': 1, 'unit': 'weeks'},
        {
          'frequency': {'rule': 'weekly', 'interval': 1}
        },
        {'endMode': 'until_date', 'endDate': '2028-01-01'},
        {'transferToStreamId': b},
        {'amount': '0'},
        {'startDate': '2027-01-20'}, // stored terms no longer fit
        {
          'loan': {...advancedLoan(), 'termMonths': 0}
        },
      ]) {
        final p = await call(events, 'PATCH', '/$loanId', body);
        expect(p.status, 400, reason: '$body -> ${p.json}');
      }
      expect(
          (await call(events, 'PATCH', '/$std', {'kind': 'loan'})).status, 400);
      expect(
          (await call(events, 'PATCH', '/$std', {'loan': advancedLoan()}))
              .status,
          400);
      // Standard events ignore a missing kind / loan, as before.
      expect((await call(events, 'PATCH', '/$std', {'amount': '120'})).status,
          200);

      // The loan's name, amount, enabled and (whole) terms can change.
      final moved = {
        ...advancedLoan(),
        'termMonths': 300,
        'ratePeriods': [
          {
            'from': '2027-02-01',
            'ratePct': '6',
            'type': 'variable',
            'interestOnly': false,
            'offsetApplies': false
          }
        ],
      };
      final p = await call(events, 'PATCH', '/$loanId', {
        'name': 'Mortgage',
        'amount': '550000',
        'startDate': '2027-02-01',
        'loan': moved,
        'kind': 'loan',
      });
      expect(p.status, 200, reason: '${p.json}');
      expect(p.json['amount'], '550000');
      expect(p.json['startDate'], '2027-02-01');
      expect(p.json['loan']['termMonths'], 300);
      expect(p.json['loan']['firstRepaymentDate'], '2027-03-01');
      expect(p.json['loan']['ratePeriods'], hasLength(1));
      expect(
          (await call(events, 'PATCH', '/$loanId', {'enabled': false})).status,
          200);
      expect(
          (await call(events, 'PATCH', '/$loanId', {'enabled': true})).status,
          200);

      // Not supported for a loan.
      for (final (m, path, body) in [
        ('PUT', '/$loanId/skips/2027-02-01', {'skipped': true}),
        (
          'PUT',
          '/$loanId/overrides/2027-02-01',
          {'amount': '1', 'direction': 'debit'}
        ),
        ('DELETE', '/$loanId/overrides/2027-02-01', null),
        ('DELETE', '/$loanId/overrides', null),
        ('POST', '/$loanId/split', {'date': '2027-02-01'}),
      ]) {
        final x = await call(events, m, path, body);
        expect(x.status, 400, reason: '$m $path');
        expect(x.json['error'], 'not supported for a loan');
      }

      // Import rejects loans per item.
      final imp = await call(
          streams,
          'POST',
          '/$b/events/import?root=2027-01-01',
          jsonEncode([
            {
              'name': 'L',
              'kind': 'loan',
              'direction': 'debit',
              'amount': '1',
              'startOffset': 0,
              'loan': advancedLoan(),
            }
          ]));
      expect(imp.status, 400);
      expect(jsonEncode(imp.json), contains('loans cannot be imported'));

      // Trim deletes the not-yet-started loan as a once-off; Undo restores
      // kind and terms exactly.
      final before = (await call(events, 'GET', '/$loanId')).json;
      final t = await call(streams, 'POST', '/$a/events/trim', {
        'date': '2027-01-25',
        'ids': [loanId],
      });
      expect(t.status, 200, reason: '${t.json}');
      expect(t.json['deleted'], [loanId]);
      expect((await call(events, 'GET', '/$loanId')).status, 404);
      final u = await call(streams, 'POST', '/$a/events/trim/undo',
          {'batchId': t.json['batchId']});
      expect(u.status, 200, reason: '${u.json}');
      final after = (await call(events, 'GET', '/$loanId')).json;
      expect(after['kind'], 'loan');
      expect(after['loan'], before['loan']);
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
