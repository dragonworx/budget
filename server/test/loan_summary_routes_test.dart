// DB-backed: runs against TEST_DATABASE_URL (default: local budget_test DB,
// never the dev DB). Skipped when Postgres is unreachable.
//
// Spec 002 group 3: /balance derived occurrences, /project loan previews,
// insights nulls, the loan-summary shape and 404, and the planner guard.
import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/scenario_repo.dart';
import 'package:budget_server/repo/stream_repo.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'loan_routes_test.dart' show advancedLoan;

const planning = "Planning isn't available for loan streams yet";

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

  const email = 'loan-summary-test@example.com';
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
              seedDate: DateTime.utc(2027, 1, 1),
              lossThreshold: Decimal.zero))
          .id;

  Map<String, Object?> loanBody() => {
        'name': 'Home loan',
        'kind': 'loan',
        'amount': '600000',
        'startDate': '2027-01-15',
        'loan': advancedLoan(),
      };

  test('balance, project, insights, loan-summary, planner guard', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    final owner = await testOwnerId(c, email);
    user = await UserRepo(c).byEmail(email);
    try {
      final a = await stream(c, owner, 'Loan');
      final b = await stream(c, owner, 'Everyday');
      final h = buildStreamsApi(c).call;

      // A scenario saved before the loan existed.
      final scen = await ScenarioRepo(c).create(
          streamId: a,
          name: 'Old plan',
          colorIndex: 0,
          included: true,
          request: {'mode': 'goal'});

      // Before the loan: planner routes are not guarded (any status but 409).
      final pre = await call(h, 'POST', '/$a/goal', {});
      expect(pre.status, isNot(409));

      final r = await call(h, 'POST', '/$a/events', loanBody());
      expect(r.status, 201, reason: '${r.json}');
      final loanId = r.json['id'] as String;
      // Repayments: $4,000 a month from Everyday on the 15th.
      final t = await call(h, 'POST', '/$b/events', {
        'name': 'Mortgage',
        'direction': 'debit',
        'amount': '4000',
        'startDate': '2027-02-15',
        'recurrenceMode': 'every',
        'interval': 1,
        'unit': 'months',
        'transferToStreamId': a,
      });
      expect(t.status, 201, reason: '${t.json}');

      // /balance: drawdown, derived monthly interest on the anniversary.
      final bal =
          await call(h, 'GET', '/$a/balance?from=2027-01-01&to=2027-03-31');
      expect(bal.status, 200);
      final occ = (bal.json['occurrences'] as List).cast<Map>();
      final derived = occ.where((o) => o['derived'] == true).toList();
      expect(derived.map((o) => o['date']), ['2027-02-15', '2027-03-15']);
      expect(derived.every((o) => o['component'] == 'interest'), isTrue);
      expect(derived.first['eventId'], loanId);
      final points = (bal.json['points'] as List).cast<Map>();
      final jan15 = points.firstWhere((p) => p['date'] == '2027-01-15');
      expect(jan15['closingBalance'], '-600000');

      // The stream lists hasLoan.
      final list = await call(h, 'GET', '/');
      final row = (list.json['streams'] as List)
          .cast<Map>()
          .firstWhere((s) => s['id'] == a);
      expect(row['hasLoan'], isTrue);

      // /insights: no alert / zero dates on a loan stream.
      final ins = await call(h, 'GET', '/$a/insights?from=2027-01-01');
      expect(ins.status, 200);
      expect(ins.json['alertDate'], isNull);
      expect(ins.json['zeroDate'], isNull);
      expect(ins.json['loan'], isTrue);
      final insB = await call(h, 'GET', '/$b/insights?from=2027-01-01');
      expect((insB.json as Map).containsKey('loan'), isFalse);
      expect(insB.json['zeroDate'], isNotNull);

      // /loan-summary shape.
      final s = await call(h, 'GET', '/$a/loan-summary?from=2027-06-01');
      expect(s.status, 200, reason: '${s.json}');
      final m = s.json as Map;
      expect(
          m.keys.toSet(),
          containsAll([
            'eventId',
            'principal',
            'startDate',
            'termEndDate',
            'balanceAt',
            'charges',
            'totalInterest',
            'totalInterestToDate',
            'payoffDate',
            'owedAtTermEnd',
            'interestType',
            'chargeSchedule',
            'chargeDay',
            'repaymentFrequency',
            'firstRepaymentDate',
            'nextChargeDate',
            'minimumRepayments',
            'flat',
            'repaymentTransfers',
            'warnings',
          ]));
      expect(m['eventId'], loanId);
      expect(m['principal'], '600000.00');
      expect(m['termEndDate'], '2057-01-15');
      expect(m['firstRepaymentDate'], '2027-02-15');
      expect(m['nextChargeDate'], '2027-06-15');
      expect(m['interestType'], 'reducing');
      expect(m['chargeDay'], 'anniversary');
      expect(m['flat'], isNull);
      expect(m['balanceAt']['date'], '2027-06-01');
      expect(Decimal.parse(m['balanceAt']['owed'] as String),
          lessThan(Decimal.fromInt(600000)));
      final mins = (m['minimumRepayments'] as List).cast<Map>();
      expect(mins, hasLength(2));
      expect(mins[1]['from'], '2029-01-15');
      expect((m['repaymentTransfers'] as List).single['amount'], '4000.00');
      expect(m['payoffDate'], isNotNull);
      expect(m['owedAtTermEnd'], startsWith('-')); // paid off early
      final w = (m['warnings'] as List).cast<String>();
      expect(w, contains('repaymentsContinueAfterPayoff'));
      expect(w, isNot(contains('belowMinimum')));
      expect(w, isNot(contains('repaymentScheduleMismatch')));
      expect(w, isNot(contains('notPaidByTermEnd')));
      final charges = (m['charges'] as List).cast<Map>();
      expect(charges.first['date'], '2027-02-15');
      final sum = charges.fold(
          Decimal.zero, (x, c) => x + Decimal.parse(c['interest'] as String));
      expect(sum.toStringAsFixed(2), m['totalInterest']);
      // Paid off on a charge day: the day's charge is the last one (no
      // accrual left for a payout charge).
      expect(charges.last['date'], m['payoffDate']);
      expect(charges.any((c) => c['payout'] == true), isFalse);

      // 404s: no loan, unknown stream.
      expect((await call(h, 'GET', '/$b/loan-summary')).status, 404);
      expect(
          (await call(h, 'GET',
                  '/00000000-0000-0000-0000-000000000000/loan-summary'))
              .status,
          404);

      // /project: a loan preview on the loan stream needs replacesEventId.
      final preview = {
        ...loanBody(),
        'amount': '500000',
      };
      final p409 = await call(h, 'POST', '/$a/project', {
        'from': '2027-01-01',
        'to': '2027-02-28',
        'events': [preview],
      });
      expect(p409.status, 409);
      final p = await call(h, 'POST', '/$a/project', {
        'from': '2027-01-01',
        'to': '2027-02-28',
        'events': [
          {...preview, 'replacesEventId': loanId}
        ],
      });
      expect(p.status, 200, reason: '${p.json}');
      final pp = (p.json['points'] as List).cast<Map>();
      expect(pp.firstWhere((x) => x['date'] == '2027-01-15')['closingBalance'],
          '-500000');
      // Feb 15: −500,000 − a month's interest (~2,500) + the 4,000 repayment.
      final feb15 = Decimal.parse(
          pp.firstWhere((x) => x['date'] == '2027-02-15')['closingBalance']);
      expect(feb15, lessThan(Decimal.fromInt(-496000)));
      expect(feb15, greaterThan(Decimal.fromInt(-500000)));

      // Planner guard.
      for (final path in ['/$a/goal', '/$a/solve', '/$a/scenarios']) {
        final g = await call(h, 'POST', path, {});
        expect(g.status, 409, reason: path);
        expect(g.json['error'], planning);
      }
      final patch =
          await call(h, 'PATCH', '/$a/scenarios/${scen.id}', {'name': 'x'});
      expect(patch.status, 409);
      expect(patch.json['error'], planning);
      // The stored scenario stays.
      final sl = await call(h, 'GET', '/$a/scenarios');
      expect((sl.json as List).single['id'], scen.id);
      // The non-loan stream is unaffected.
      expect((await call(h, 'POST', '/$b/goal', {})).status, isNot(409));
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  });
}
