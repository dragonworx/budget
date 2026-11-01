// DB-backed (budget_test only): perf_seed writes its synthetic streams and
// /balance over 35 years is timed on each (spec 005 R2). Tagged perf;
// skipped when Postgres is unreachable. Prints p50 / p95 per stream.
@Tags(['perf'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:budget_server/api/streams.dart';
import 'package:budget_server/auth/middleware.dart';
import 'package:budget_server/config.dart';
import 'package:budget_server/db.dart';
import 'package:budget_server/repo/user_repo.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../tool/perf_seed.dart';
import 'helpers.dart';

void main() {
  Connection? conn;
  final url = Platform.environment['TEST_DATABASE_URL'] ??
      'postgres://budget:budget@127.0.0.1:5432/budget_test';
  setUpAll(() async {
    try {
      conn = await openConnection(Config(databaseUrl: url, host: '', port: 0));
      await applyMigrations(conn!, migrationsDir: 'migrations');
    } catch (_) {
      conn = null;
    }
  });
  tearDownAll(() async => conn?.close());

  test('perf_seed refuses databases other than *_perf / budget_test', () {
    expect(perfDbAllowed('postgres://u:p@h:5432/budget_perf'), isTrue);
    expect(perfDbAllowed('postgres://u:p@h:5432/budget_test'), isTrue);
    expect(perfDbAllowed('postgres://u:p@h:5432/budget'), isFalse);
    expect(perfDbAllowed('postgres://u:p@h:5432/budget_perf_x'), isFalse);
    expect(perfDbAllowed('postgres://u:p@h:5432/'), isFalse);
    expect(perfDbAllowed(''), isFalse);
  });

  test('perf plans are deterministic and shaped as specified', () {
    final seed = DateTime.utc(2026, 11, 1);
    final a = planStream('PERF 5k', seed, perfMixes['PERF 5k']!);
    final b = planStream('PERF 5k', seed, perfMixes['PERF 5k']!);
    expect(jsonEncode([for (final e in a.events) e.body()]),
        jsonEncode([for (final e in b.events) e.body()]));
    expect(a.thresholdCents, b.thresholdCents);
    final big = planStream('PERF 50k', seed, perfMixes['PERF 50k']!);
    expect(big.occurrences, inInclusiveRange(45000, 65000));
    expect({for (final e in big.events) e.cadence}, PerfCadence.values.toSet());
    expect(big.events.any((e) => e.skips.isNotEmpty), isTrue);
  });

  test('perf_seed streams: /balance 35y timing', () async {
    final c = conn;
    if (c == null) return markTestSkipped('no test database');
    if (!perfDbAllowed(url)) return markTestSkipped('not a perf database');
    const email = 'perf-seed-test@example.com';
    final owner = await testOwnerId(c, email);
    final user = (await UserRepo(c).byEmail(email))!;
    final seedDate = DateTime.utc(2026, 11, 1);
    try {
      final ids = await seedPerf(c, user,
          seedDate: seedDate, sizes: const ['5k', '50k']);
      final h = buildStreamsApi(c).call;
      for (final name in ['PERF 5k', 'PERF 50k', 'PERF Loan']) {
        final id = ids[name]!;
        Future<Map<String, dynamic>> balance() async {
          final r = await h(Request('GET',
              Uri.parse('http://x/$id/balance?from=2026-11-01&to=2061-11-01'),
              context: {'auth': AuthContext(user, 't')}));
          expect(r.statusCode, 200);
          return jsonDecode(await r.readAsString()) as Map<String, dynamic>;
        }

        final body = await balance();
        final ms = <int>[];
        for (var i = 0; i < 5; i++) {
          final sw = Stopwatch()..start();
          await balance();
          ms.add(sw.elapsedMilliseconds);
        }
        ms.sort();
        final occ = body['occurrences'] as List;
        final points = body['points'] as List;
        print('perf: $name /balance 35y ${occ.length} occ, '
            '${points.length} days: p50 ${ms[2]}ms, max ${ms[4]}ms');
        expect(occ, isNotEmpty);
        if (name != 'PERF Loan') {
          expect(occ.any((o) => o['skipped'] == true), isTrue);
          // The threshold (median close) is crossed at least 5 times.
          final stream = jsonDecode(await (await h(Request(
                  'GET', Uri.parse('http://x/$id'),
                  context: {'auth': AuthContext(user, 't')})))
              .readAsString()) as Map<String, dynamic>;
          final threshold = double.parse(stream['lossThreshold'].toString());
          var crossings = 0;
          bool? below;
          for (final p in points) {
            final v = double.parse(p['closingBalance'].toString());
            final now = v < threshold;
            if (below != null && now != below) crossings++;
            below = now;
          }
          expect(crossings, greaterThanOrEqualTo(5));
        }
      }
    } finally {
      await deleteOwnedStreams(c, owner);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
