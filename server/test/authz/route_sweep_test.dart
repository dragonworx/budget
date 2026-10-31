// Ensures every API route is covered by the authz policy table (default
// deny), and that every policy actually denies anonymous users and
// outsiders when exercised end-to-end.
import 'dart:io';

import 'package:budget_server/auth/authz.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// file -> function name -> mount prefix below /api.
const _mounts = {
  'streams.dart': {'buildStreamsApi': 'streams'},
  'balance.dart': {'attachBalanceRoutes': 'streams'},
  'loan_summary.dart': {'attachLoanSummaryRoute': 'streams'},
  'goal.dart': {'attachGoalRoutes': 'streams'},
  'stream_view.dart': {'attachStreamViewRoutes': 'streams'},
  'solve.dart': {'attachSolveRoutes': 'streams'},
  'scenarios.dart': {'attachScenarioRoutes': 'streams'},
  'categories.dart': {'attachCategoryRoutes': 'streams'},
  'events.dart': {'eventsRouter': 'events'},
  'sharing.dart': {
    'attachStreamSharingRoutes': 'streams',
    'buildInvitesApi': 'invites',
  },
  'admin.dart': {'buildAdminApi': 'admin'},
  'live.dart': {'buildLiveApi': 'live'},
};

/// All `(METHOD, path-below-/api)` registered on routers in lib/api.
List<(String, String)> registeredRoutes() {
  final out = <(String, String)>[];
  final fnRe = RegExp(r'^(?:Router|void|Handler)\s+(\w+)\(', multiLine: true);
  final routeRe = RegExp(r"router\.(get|post|put|patch|delete)\(\s*'([^']*)'",
      multiLine: true);
  for (final f in Directory('lib/api').listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final src = f.readAsStringSync();
    if (!routeRe.hasMatch(src) || name == 'auth.dart') continue;
    final fns = _mounts[name];
    if (fns == null) {
      fail('lib/api/$name registers routes but has no mount entry');
    }
    final starts = fnRe.allMatches(src).toList();
    for (final m in routeRe.allMatches(src)) {
      final fn = starts.lastWhere((s) => s.start < m.start).group(1)!;
      final prefix = fns[fn];
      if (prefix == null) fail('$name: routes in $fn() have no mount entry');
      final sub = m.group(2)!.replaceAll(RegExp(r'^/|/$'), '');
      final path = [prefix, if (sub.isNotEmpty) sub]
          .join('/')
          .replaceAllMapped(RegExp(r'<(\w+)>'), (x) => ':${x[1]}');
      out.add((m.group(1)!.toUpperCase(), path));
    }
  }
  // router.dart also mounts the live (SSE) router at the deprecated
  // pre-rename path GET /api/events.
  out.add(('GET', 'events'));
  return out;
}

String _shape(String p) =>
    p.split('/').map((s) => s.startsWith(':') ? ':' : s).join('/');

void main() {
  test('every registered route has an authz policy, and vice versa', () {
    final routes = registeredRoutes();
    expect(routes.length, greaterThan(40));
    final policyShapes = {
      for (final p in policies) '${p.method} ${_shape(p.path)}'
    };
    final routeShapes = {for (final r in routes) '${r.$1} ${_shape(r.$2)}'};
    expect(routeShapes.difference(policyShapes), isEmpty,
        reason: 'routes without a policy (they would be denied)');
    expect(policyShapes.difference(routeShapes), isEmpty,
        reason: 'policies without a route (stale entries)');
  });

  test('mutating policies all emit an audit event', () {
    for (final p in policies) {
      final mutating = p.method != 'GET';
      final computeOnly = p.path.endsWith('/project') ||
          p.path.endsWith('/solve') ||
          p.path.endsWith('/goal') ||
          p.path.startsWith('invites/preview') ||
          // A per-user preference (landing stream), not shared data.
          p.path.endsWith('/opened') ||
          // Each member's own saved timeline view, likewise.
          p.path.endsWith('/view');
      if (mutating && !computeOnly) {
        expect(p.event, isNotNull, reason: '${p.method} ${p.path}');
      }
    }
  });

  group('end-to-end sweep', () {
    final h = Harness('sweep.authtest.example');
    setUpAll(() => h.open());
    tearDownAll(() => h.close());

    test('anonymous -> 401 and outsiders -> 404/403 on every policy', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('owner', 'Sweep');
      final sc = await h
          .call('POST', '/api/streams/${s.a}/scenarios', as: 'owner', body: {
        'name': 'S',
        'request': {'solveFor': 'amount'}
      });
      final inv = await h.call('POST', '/api/streams/${s.a}/invites',
          as: 'owner', body: {'email': h.email('pending')});
      final ownerId = await h.userId('owner');
      final ids = {
        'a': s.a,
        't': s.t,
        's': (sc.json?['id'] ?? '00000000-0000-0000-0000-000000000000')
            as String,
        'u': ownerId,
        'i': inv.json['id'] as String,
        'd': '2026-01-01',
        'pattern': '@nowhere.example',
        'c': (await h.call('GET', '/api/events/${s.t}', as: 'owner'))
            .json['categoryId'] as String,
      };
      await h.login('outsider');
      for (final p in policies) {
        final path =
            '/api/${p.path.split('/').map((x) => x.startsWith(':') ? ids[x.substring(1)]! : x).join('/')}';
        final body = p.method == 'GET' || p.method == 'DELETE'
            ? null
            : <String, Object?>{};
        final anon = await h.call(p.method, path, body: body);
        expect(anon.status, 401, reason: 'anonymous ${p.method} $path');
        final out = await h.call(p.method, path, as: 'outsider', body: body);
        final expected = switch (p.scope) {
          Scope.auth => isNot(anyOf(401, 404, 500)),
          Scope.admin => 403,
          _ => 404,
        };
        expect(out.status, expected,
            reason: 'outsider ${p.method} $path -> ${out.json}');
      }
      // Unknown routes are denied even when signed in.
      expect((await h.call('GET', '/api/secret-debug', as: 'outsider')).status,
          404);
      expect(
          (await h.call('DELETE', '/api/streams', as: 'outsider')).status, 404);
      // Projects are gone: tabs on an old build get 410 "please reload"
      // (shown as is by old builds), signed in or not.
      for (final r in [
        await h.call('GET', '/api/projects', as: 'outsider'),
        await h.call('GET', '/api/projects/x/streams', as: 'outsider'),
        await h
            .call('POST', '/api/projects', as: 'outsider', body: {'name': 'x'}),
        await h.call('GET', '/api/projects'),
        // Accounts were renamed to streams.
        await h.call('GET', '/api/accounts', as: 'outsider'),
        await h.call('GET', '/api/accounts/x/events', as: 'outsider'),
        await h.call('GET', '/api/accounts'),
      ]) {
        expect(r.status, 410);
        expect(r.json['error'], contains('reload'));
        expect(r.json['details']['code'], 'client_outdated');
      }
      // Not a prefix match on other names.
      expect(
          (await h.call('GET', '/api/projectsX', as: 'outsider')).status, 404);
    });

    test(
        'viewers -> 403 on every write that needs editor; editors -> 403 '
        'on owner-only ones; nothing changes', () async {
      if (!h.ok) return markTestSkipped('no test DB');
      final s = await h.seed('rowner', 'RoleSweep');
      await h.login('rviewer');
      await h.login('reditor');
      await h.call('POST', '/api/streams/${s.a}/invites',
          as: 'rowner', body: {'email': h.email('rviewer')});
      await h.call('POST', '/api/streams/${s.a}/invites',
          as: 'rowner', body: {'email': h.email('reditor'), 'role': 'editor'});
      final sc = await h
          .call('POST', '/api/streams/${s.a}/scenarios', as: 'rowner', body: {
        'name': 'S',
        'request': {'solveFor': 'amount'}
      });
      final inv = await h.call('POST', '/api/streams/${s.a}/invites',
          as: 'rowner', body: {'email': h.email('rpending')});
      final ids = {
        'a': s.a,
        't': s.t,
        's': sc.json['id'] as String,
        'u': await h.userId('rviewer'),
        'i': inv.json['id'] as String,
        'd': '2026-01-01',
        'c': (await h.call('GET', '/api/events/${s.t}', as: 'rowner'))
            .json['categoryId'] as String,
      };
      final before =
          (await h.call('GET', '/api/streams/${s.a}/events', as: 'rowner'))
              .json;
      var checked = 0;
      for (final p in policies) {
        if (p.scope != Scope.stream &&
            p.scope != Scope.event &&
            p.scope != Scope.invite) {
          continue;
        }
        final path =
            '/api/${p.path.split('/').map((x) => x.startsWith(':') ? ids[x.substring(1)]! : x).join('/')}';
        final body = p.method == 'GET' || p.method == 'DELETE'
            ? null
            : <String, Object?>{};
        for (final (who, role) in [
          ('rviewer', Role.viewer),
          ('reditor', Role.editor),
        ]) {
          if (role.atLeast(p.min)) continue;
          final r = await h.call(p.method, path, as: who, body: body);
          expect(r.status, 403, reason: '$who ${p.method} $path -> ${r.json}');
          checked++;
        }
      }
      expect(checked, greaterThan(20));
      final after =
          (await h.call('GET', '/api/streams/${s.a}/events', as: 'rowner'))
              .json;
      expect(after, before, reason: 'denied writes change nothing');
      expect((await h.call('GET', '/api/streams/${s.a}', as: 'rowner')).status,
          200);
    });
  });
}
