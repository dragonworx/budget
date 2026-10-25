// Regressions from the Oct 2026 audit. DB-backed (TEST_DATABASE_URL);
// skipped without Postgres.
import 'package:budget_server/api/balance.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  test('checkBalanceRange: order and ~100-year cap', () {
    final d = DateTime.utc(2026, 1, 1);
    checkBalanceRange(d, d);
    checkBalanceRange(d, d.add(const Duration(days: maxBalanceRangeDays)));
    expect(() => checkBalanceRange(d, d.subtract(const Duration(days: 1))),
        throwsFormatException);
    expect(
        () => checkBalanceRange(
            d, d.add(const Duration(days: maxBalanceRangeDays + 1))),
        throwsFormatException);
    // A short window far after the seed still walks from the seed.
    expect(
        () => checkBalanceRange(DateTime.utc(9000), DateTime.utc(9000, 2),
            seed: d),
        throwsFormatException);
    checkBalanceRange(DateTime.utc(2050), DateTime.utc(2051), seed: d);
    // Oldest picker seed (1970) to the latest picker date (2100) is fine.
    checkBalanceRange(DateTime.utc(2090), DateTime.utc(2100),
        seed: DateTime.utc(1970));
  });

  group('api', () {
    final h = Harness('audit.authtest.example');
    setUpAll(() => h.open());
    tearDownAll(() => h.close());

    test('balance/project reject unbounded or reversed ranges (400)', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('owner', 'Ranges');
      final ok = await h.call(
          'GET', '/api/streams/${s.a}/balance?from=2026-01-01&to=2125-12-31',
          as: 'owner');
      expect(ok.status, 200);
      for (final q in [
        'from=0001-01-01&to=9999-12-31',
        'from=2026-01-01&to=2025-12-31',
        'from=9000-01-01&to=9000-02-01',
      ]) {
        final r =
            await h.call('GET', '/api/streams/${s.a}/balance?$q', as: 'owner');
        expect(r.status, 400, reason: q);
      }
      final p = await h.call('POST', '/api/streams/${s.a}/project',
          as: 'owner',
          body: {'from': '0001-01-01', 'to': '9999-12-31', 'events': []});
      expect(p.status, 400);
      expect(p.json['error'], contains('range too long'));
      final ins = await h.call(
          'GET', '/api/streams/${s.a}/insights?from=9000-01-01',
          as: 'owner');
      expect(ins.status, 400);
      expect(
          (await h.call('GET', '/api/streams/${s.a}/insights', as: 'owner'))
              .status,
          200);
      final g =
          await h.call('POST', '/api/streams/${s.a}/goal', as: 'owner', body: {
        'solveFor': 'amount',
        'startDate': '9000-01-01',
        'endDate': '9000-06-01',
        'targetBalance': 100,
      });
      expect(g.status, 400, reason: '${g.json}');
      final sv =
          await h.call('POST', '/api/streams/${s.a}/solve', as: 'owner', body: {
        'direction': 'credit',
        'unit': 'weeks',
        'targetBalance': '100',
        'endDate': '9999-01-01',
      });
      expect(sv.status, 400, reason: '${sv.json}');
      // Normal goals still solve.
      final ok2 =
          await h.call('POST', '/api/streams/${s.a}/goal', as: 'owner', body: {
        'solveFor': 'amount',
        'startDate': '2026-02-01',
        'endDate': '2026-12-01',
        'targetBalance': 100,
      });
      expect(ok2.status, 200, reason: '${ok2.json}');
    });

    test('reorder keeps only the stream\'s own event ids', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('owner', 'Reorder');
      final other = await h.seed('owner', 'ReorderOther');
      final r = await h.call('PATCH', '/api/streams/${s.a}/reorder-events',
          as: 'owner',
          body: {
            'eventIds': [other.t, s.t, s.t, 'not-a-uuid']
          });
      expect(r.status, 200, reason: '${r.json}');
      expect(r.json['eventOrder'], [s.t]);
    });
  });
}
