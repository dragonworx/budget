// Ensures every API route is covered by the authz policy table (default
// deny), and that every policy actually denies anonymous users and
// outsiders when exercised end-to-end.
import 'dart:io';

import 'package:budget_server/auth/authz.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// file -> function name -> mount prefix below /api.
const _mounts = {
  'projects.dart': {'buildProjectsApi': 'projects'},
  'accounts.dart': {'buildAccountsApi': 'accounts'},
  'balance.dart': {'attachBalanceRoutes': 'accounts'},
  'goal.dart': {'attachGoalRoutes': 'accounts'},
  'solve.dart': {'attachSolveRoutes': 'accounts'},
  'scenarios.dart': {'attachScenarioRoutes': 'accounts'},
  'transactions.dart': {'transactionsRouter': 'transactions'},
  'sharing.dart': {
    'attachProjectSharingRoutes': 'projects',
    'attachAccountSharingRoutes': 'accounts',
    'buildInvitesApi': 'invites',
  },
  'admin.dart': {'buildAdminApi': 'admin'},
  'events.dart': {'buildEventsApi': 'events'},
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
          p.path.startsWith('invites/preview');
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
          .call('POST', '/api/accounts/${s.a}/scenarios', as: 'owner', body: {
        'name': 'S',
        'request': {'solveFor': 'amount'}
      });
      final inv = await h.call('POST', '/api/projects/${s.p}/invites',
          as: 'owner', body: {'email': h.email('pending')});
      final ownerId = await h.userId('owner');
      final ids = {
        'p': s.p,
        'a': s.a,
        't': s.t,
        's': (sc.json?['id'] ?? '00000000-0000-0000-0000-000000000000')
            as String,
        'u': ownerId,
        'i': inv.json['id'] as String,
        'd': '2026-01-01',
        'pattern': '@nowhere.example',
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
      expect((await h.call('DELETE', '/api/projects', as: 'outsider')).status,
          404);
    });
  });
}
