import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../api/json_helpers.dart';
import '../repo/account_repo.dart';
import '../repo/audit_repo.dart';
import '../repo/project_repo.dart';
import '../repo/scenario_repo.dart';
import '../repo/transaction_repo.dart';
import 'authz.dart';
import 'middleware.dart';

Access? accessOf(Request r) => r.context['access'] as Access?;

/// Role-based authorization for every authenticated `/api` route, plus:
/// - transfer checks (editor on both sides; no peer leaks),
/// - optimistic concurrency (`If-Match` / body `version` on PATCH -> 409),
/// - an audit_log row for every successful mutation.
/// Unknown routes are denied (404). No access -> 404; too low a role -> 403.
Middleware authzMiddleware(Session db) {
  final authz = Authz(db);
  final audit = AuditRepo(db);
  return (inner) => (request) async {
        final auth = authOf(request);
        final seg = request.url.pathSegments;
        if (auth == null || seg.isEmpty || seg[0] != 'api') {
          return inner(request);
        }
        if (seg.length > 1 && seg[1] == 'auth') return inner(request);
        final rest = seg.sublist(1);
        final found = findPolicy(request.method, rest);
        if (found == null) return jsonError(404, 'not found');
        final (policy, params) = found;
        final uid = auth.user.id;

        Access? access;
        switch (policy.scope) {
          case Scope.auth:
            access = Access(params: params);
          case Scope.admin:
            if (!auth.user.isAdmin) return jsonError(403, 'admin only');
            access = Access(params: params);
          case Scope.project:
            final r = await authz.projectRole(params['p']!, uid);
            if (r != null) {
              access = Access(
                  role: r,
                  projectRole: r,
                  projectId: params['p'],
                  params: params);
            }
          case Scope.projectView:
            final a = await authz.projectView(params['p']!, uid);
            if (a != null) {
              access = Access(
                  role: a.role,
                  projectRole: a.projectRole,
                  projectId: a.projectId,
                  limited: a.limited,
                  params: params);
            }
          case Scope.account:
          case Scope.accountProject:
            final a = await authz.account(params['a']!, uid);
            if (a != null) {
              final role =
                  policy.scope == Scope.account ? a.role : a.projectRole;
              access = Access(
                  role: role,
                  projectRole: a.projectRole,
                  projectId: a.projectId,
                  accountId: a.accountId,
                  params: params);
            }
          case Scope.transaction:
            final ta = await authz.transactionAccounts(params['t']!);
            if (ta != null) {
              final a = await authz.account(ta.$1, uid);
              if (a != null) {
                access = Access(
                    role: a.role,
                    projectRole: a.projectRole,
                    projectId: a.projectId,
                    accountId: a.accountId,
                    params: {...params, if (ta.$2 != null) 'peer': ta.$2!});
              }
            }
          case Scope.invite:
            final p = await authz.inviteProject(params['i']!);
            final r = p == null ? null : await authz.projectRole(p, uid);
            if (r != null) {
              access =
                  Access(role: r, projectRole: r, projectId: p, params: params);
            }
        }
        if (access == null) return jsonError(404, 'not found');
        final scoped =
            policy.scope != Scope.auth && policy.scope != Scope.admin;
        if (scoped) {
          // A user who holds nothing usable at this scope cannot see it.
          if (access.role == null) return jsonError(404, 'not found');
          if (!access.role!.atLeast(policy.min)) {
            return jsonError(403, 'requires ${policy.min.name} role',
                details: {'role': access.role!.name});
          }
        }

        // Body-dependent checks for mutations.
        final mutating = request.method != 'GET' && request.method != 'HEAD';
        Map<String, dynamic>? body;
        if (mutating) {
          final raw = await request.readAsString();
          request = request.change(body: raw);
          try {
            final d = raw.trim().isEmpty ? null : jsonDecode(raw);
            if (d is Map<String, dynamic>) body = d;
          } catch (_) {}

          // Transfers: editor on the target account, and on the existing
          // peer of a linked row being changed.
          final to = body?['transferToAccountId'];
          if (to != null) {
            final t = await authz.account('$to', uid);
            if (t == null) return jsonError(404, 'transfer account not found');
            if (!t.role!.atLeast(Role.editor)) {
              return jsonError(403, 'requires editor role on transfer account');
            }
          }
          final peer = access.params['peer'];
          if (policy.scope == Scope.transaction && peer != null) {
            final p = await authz.account(peer, uid);
            if (p == null || !p.role!.atLeast(Role.editor)) {
              return jsonError(
                  403, 'requires editor role on the linked transfer account');
            }
          }

          // Optimistic concurrency.
          if (policy.versioned != null) {
            final expected = _expectedVersion(request, body);
            if (expected != null) {
              final current = await _current(db, policy.versioned!, params);
              if (current != null && current['version'] != expected) {
                final redacted =
                    await _redact(authz, uid, current) as Map<String, dynamic>;
                return jsonError(409, 'version conflict',
                        details: {'current': redacted})
                    .change(headers: {'x-conflict': 'version'});
              }
            }
          }
        }

        final res = await inner(request.change(context: {'access': access}));

        // Peer redaction on JSON that may contain transfer links.
        var out = res;
        if ((res.headers['content-type'] ?? '').contains('json') &&
            (rest[0] == 'accounts' || rest[0] == 'transactions')) {
          final text = await res.readAsString();
          if (text.contains('"peerAccountId"')) {
            final redacted = await _redact(authz, uid, jsonDecode(text));
            out = res.change(body: jsonEncode(redacted));
          } else {
            out = res.change(body: text);
          }
        }

        if (mutating &&
            policy.event != null &&
            res.statusCode >= 200 &&
            res.statusCode < 300) {
          String? created;
          Map<String, dynamic>? resJson;
          if (out.headers['content-type']?.contains('json') ?? false) {
            final text = await out.readAsString();
            out = out.change(body: text);
            try {
              final d = jsonDecode(text);
              if (d is Map<String, dynamic>) resJson = d;
            } catch (_) {}
            created = resJson?['id']?.toString();
          }
          await audit.recordRequest(
            userId: uid,
            policy: policy,
            access: access,
            params: params,
            createdId: created,
            response: resJson,
          );
        }
        return out;
      };
}

int? _expectedVersion(Request r, Map<String, dynamic>? body) {
  final h = r.headers['if-match'];
  if (h != null) {
    final v = int.tryParse(h.replaceAll(RegExp(r'^W/|"'), '').trim());
    if (v != null) return v;
  }
  final b = body?['version'];
  if (b is int) return b;
  if (b is String) return int.tryParse(b);
  return null;
}

Future<Map<String, dynamic>?> _current(
    Session db, String table, Map<String, String> p) async {
  Object? json;
  switch (table) {
    case 'projects':
      json = (await ProjectRepo(db).get(p['p']!))?.toJson();
    case 'accounts':
      json = (await AccountRepo(db).get(p['a']!))?.toJson();
    case 'transactions':
      json = (await TransactionRepo(db).get(p['t']!))?.toJson();
    case 'scenarios':
      final s = await ScenarioRepo(db).get(p['s']!);
      json = s != null && s.accountId == p['a'] ? s.toJson() : null;
  }
  return json == null
      ? null
      : jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
}

/// Nulls peer account/project names (and project id) on transfer links whose
/// peer account the user cannot read; marks them `peerReadable: false`.
Future<Object?> _redact(Authz authz, String uid, Object? json) async {
  final links = <Map<String, dynamic>>[];
  void walk(Object? n) {
    if (n is Map<String, dynamic>) {
      if (n.containsKey('peerAccountId')) links.add(n);
      n.values.forEach(walk);
    } else if (n is List) {
      n.forEach(walk);
    }
  }

  walk(json);
  if (links.isEmpty) return json;
  final ids = links.map((l) => l['peerAccountId']).whereType<String>();
  final readable = await authz.readableAccounts(ids, uid);
  for (final l in links) {
    final id = l['peerAccountId'];
    final ok = id == null || readable.contains(id);
    l['peerReadable'] = ok;
    if (!ok) {
      l['peerAccountName'] = null;
      l['peerProjectName'] = null;
      l['peerProjectId'] = null;
    }
  }
  return json;
}
