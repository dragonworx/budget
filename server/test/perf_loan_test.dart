// DB-backed timing check (spec 002): p95 of 20 runs of /balance and
// /loan-summary on a 35-year loan stream with 3 recurring events must be
// <= 150 ms; with one offset linked (spec 004) <= 200 / 300 ms. Also prints a 7-event 20-year non-loan /balance p95 (the
// before/after benchmark). Skipped when Postgres is unreachable.
@Tags(['perf'])
library;

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
import 'perf_nonloan.dart';

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

  const email = 'perf-loan-test@example.com';

  test('35-year loan stream: /balance and /loan-summary p95 <= 150 ms',
      () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    final user = (await UserRepo(c).byEmail(email))!;
    final h = buildStreamsApi(c).call;
    Future<Response> req(String method, String path, [Object? body]) =>
        h(Request(method, Uri.parse('http://x$path'),
            context: {'auth': AuthContext(user, 't')},
            body: body == null ? null : jsonEncode(body)));
    try {
      final repo = StreamRepo(c);
      final a = (await repo.create(
              ownerId: owner,
              name: 'Loan',
              seedBalance: Decimal.zero,
              seedDate: DateTime.utc(2027, 1, 1),
              lossThreshold: Decimal.zero))
          .id;
      final b = (await repo.create(
              ownerId: owner,
              name: 'Everyday',
              seedBalance: Decimal.fromInt(5000),
              seedDate: DateTime.utc(2027, 1, 1),
              lossThreshold: Decimal.zero))
          .id;
      Future<Map<String, dynamic>> post(
          String s, Map<String, Object?> body) async {
        final r = await req('POST', '/$s/events', body);
        final text = await r.readAsString();
        expect(r.statusCode, 201, reason: text);
        return jsonDecode(text) as Map<String, dynamic>;
      }

      final loan = await post(a, {
        'name': 'Home loan',
        'kind': 'loan',
        'amount': '750000',
        'startDate': '2027-01-15',
        'loan': {
          'v': 1,
          'mode': 'advanced',
          'interestType': 'reducing',
          'termMonths': 420,
          'repaymentFrequency': 'fortnightly',
          'chargeSchedule': 'monthly',
          'chargeDay': 'monthEnd',
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
              'from': '2030-01-15',
              'ratePct': '6.40',
              'type': 'variable',
              'interestOnly': false,
              'offsetApplies': true
            },
          ],
        },
      });
      // 3 recurring events in the loan stream: fortnightly repayment
      // (transfer in), monthly fee, weekly offset top-up.
      await post(b, {
        'name': 'Repayment',
        'direction': 'debit',
        'amount': '1950',
        'startDate': '2027-01-29',
        'recurrenceMode': 'every',
        'interval': 2,
        'unit': 'weeks',
        'transferToStreamId': a,
      });
      await post(a, {
        'name': 'Account fee',
        'direction': 'debit',
        'amount': '10',
        'startDate': '2027-01-31',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'months',
      });
      await post(a, {
        'name': 'Extra',
        'direction': 'credit',
        'amount': '50',
        'startDate': '2027-01-20',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'weeks',
      });

      final balance = await p95(20, () async {
        final r = await req('GET', '/$a/balance?from=2027-01-01&to=2062-01-15');
        expect(r.statusCode, 200);
        await r.readAsString();
      });
      final summary = await p95(20, () async {
        final r = await req('GET', '/$a/loan-summary?from=2030-06-01');
        expect(r.statusCode, 200);
        await r.readAsString();
      });
      final nonLoan = await nonLoanBalanceP95(c, owner, user, h);
      print('perf p95: /balance 35y loan ${balance}ms, '
          '/loan-summary ${summary}ms, non-loan 7-event 20y ${nonLoan}ms');
      expect(balance, lessThanOrEqualTo(150));
      expect(summary, lessThanOrEqualTo(150));

      // Spec 004 §13: the same loan with Everyday (repayments out, salary
      // in) linked as its offset: <= 200 ms /balance, <= 300 ms summary.
      await post(b, {
        'name': 'Salary',
        'direction': 'credit',
        'amount': '4200',
        'startDate': '2027-01-14',
        'recurrenceMode': 'every',
        'interval': 2,
        'unit': 'weeks',
      });
      final link = await eventsRouter(c)
          .call(Request('PATCH', Uri.parse('http://x/${loan['id']}'),
              context: {'auth': AuthContext(user, 't')},
              body: jsonEncode({
                'version': loan['version'],
                'offsetStreamIds': [b]
              })));
      final linkText = await link.readAsString();
      expect(link.statusCode, 200, reason: linkText);
      final oBalance = await p95(20, () async {
        final r = await req('GET', '/$a/balance?from=2027-01-01&to=2062-01-15');
        expect(r.statusCode, 200);
        await r.readAsString();
      });
      final oSummary = await p95(20, () async {
        final r = await req('GET', '/$a/loan-summary?from=2030-06-01');
        expect(r.statusCode, 200);
        final j = jsonDecode(await r.readAsString());
        expect(j['offset'], isNotNull);
      });
      print('perf p95 with one offset: /balance 35y loan ${oBalance}ms, '
          '/loan-summary ${oSummary}ms');
      expect(oBalance, lessThanOrEqualTo(200));
      expect(oSummary, lessThanOrEqualTo(300));
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
