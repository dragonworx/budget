// Saved timeline views: per user per stream, members only, validated, never
// audited/broadcast. DB-backed (TEST_DATABASE_URL); skipped without Postgres.
import 'package:budget_server/api/stream_view.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'authz/harness.dart';

void main() {
  group('parseStreamView', () {
    test('clamps span, start and balance range', () {
      final v = parseStreamView({
        'start': 1e9,
        'days': 1e6,
        'unit': 'year',
        'yMin': -1e20,
        'yMax': 5,
      });
      expect(v.startDay, maxViewStartDay);
      expect(v.days, maxViewDays);
      expect(v.yMin, -maxViewBalance);
      expect(v.yMax, 5);
      // A 30-year view (spec 003 §15) is kept; 35 years is the limit.
      expect(parseStreamView({'start': 20000, 'days': 10958}).days, 10958);
      expect(maxViewDays, 12785);
      final w = parseStreamView({'start': -1e9, 'days': 0.01});
      expect(w.startDay, minViewStartDay);
      expect(w.days, minViewDays);
      expect(w.unit, isNull);
      expect(w.yMin, isNull);
    });

    test('rejects malformed views', () {
      for (final b in <Map<String, dynamic>>[
        {},
        {'start': 20000},
        {'start': 'x', 'days': 30},
        {'start': 20000, 'days': 30, 'unit': 'fortnight'},
        {'start': 20000, 'days': 30, 'yMin': 1},
        {'start': 20000, 'days': 30, 'yMin': 5, 'yMax': 5},
        {'start': 20000, 'days': 30, 'yMin': 9, 'yMax': 1},
        {'start': 20000, 'days': double.nan},
      ]) {
        expect(() => parseStreamView(b), throwsFormatException, reason: '$b');
      }
    });
  });

  group('api', () {
    final h = Harness('view.authtest.example');
    setUpAll(() => h.open());
    tearDownAll(() => h.close());

    Map<String, Object?> view(double start, {double y = 1000}) => {
          'start': start,
          'days': 61.5,
          'unit': 'months2',
          'yMin': -y / 3,
          'yMax': y,
        };

    test('members only; each member keeps their own view', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('vowner', 'Views');
      await h.login('vviewer');
      await h.login('voutsider');
      await h.call('POST', '/api/streams/${s.a}/invites',
          as: 'vowner', body: {'email': h.email('vviewer')});
      final path = '/api/streams/${s.a}/view';

      // Nothing saved yet.
      final none = await h.call('GET', path, as: 'vowner');
      expect(none.status, 200);
      expect(none.json['view'], isNull);

      // Outsiders can neither read nor write it.
      expect((await h.call('GET', path, as: 'voutsider')).status, 404);
      expect((await h.call('PUT', path, as: 'voutsider', body: view(1))).status,
          404);

      final auditBefore = await h.conn!.execute(
          Sql.named(
              'SELECT count(*) FROM audit_log WHERE stream_id = @a::uuid'),
          parameters: {'a': s.a});

      // Owner and viewer (read-only role) both save their own.
      final o = await h.call('PUT', path, as: 'vowner', body: view(20700.25));
      expect(o.status, 200);
      final v = await h.call('PUT', path,
          as: 'vviewer', body: view(20800.5, y: 5000));
      expect(v.status, 200);

      final og = (await h.call('GET', path, as: 'vowner')).json['view'] as Map;
      final vg = (await h.call('GET', path, as: 'vviewer')).json['view'] as Map;
      expect(og['start'], 20700.25);
      expect(og['yMax'], 1000);
      expect(og['unit'], 'months2');
      expect(vg['start'], 20800.5);
      expect(vg['yMax'], 5000);

      // Overwrite is an upsert of the caller's row only.
      await h.call('PUT', path, as: 'vowner', body: view(20701));
      expect(
          ((await h.call('GET', path, as: 'vviewer')).json['view']
              as Map)['start'],
          20800.5);
      expect(
          ((await h.call('GET', path, as: 'vowner')).json['view']
              as Map)['start'],
          20701);

      // Not stream data: no audit rows, so nothing is broadcast.
      final auditAfter = await h.conn!.execute(
          Sql.named(
              'SELECT count(*) FROM audit_log WHERE stream_id = @a::uuid'),
          parameters: {'a': s.a});
      expect(auditAfter.first[0], auditBefore.first[0]);

      // Validation.
      final bad = await h.call('PUT', path,
          as: 'vowner', body: {'start': 1, 'days': 30, 'unit': 'nope'});
      expect(bad.status, 400);
      final clamped = await h.call('PUT', path,
          as: 'vowner', body: {'start': 20000, 'days': 99999});
      expect(clamped.status, 200);
      expect((clamped.json['view'] as Map)['days'], maxViewDays);

      // Deleting the stream drops every member's view.
      await h.call('DELETE', '/api/streams/${s.a}', as: 'vowner');
      final left = await h.conn!.execute(
          Sql.named(
              'SELECT count(*) FROM stream_views WHERE stream_id = @a::uuid'),
          parameters: {'a': s.a});
      expect(left.first[0], 0);
    });
  });
}
