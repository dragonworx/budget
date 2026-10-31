import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../api/json_helpers.dart';
import '../db_scope.dart';
import '../repo/stream_repo.dart';
import '../repo/audit_repo.dart';
import '../repo/scenario_repo.dart';
import '../repo/event_repo.dart';
import 'authz.dart';
import 'middleware.dart';

Access? accessOf(Request r) => r.context['access'] as Access?;

/// Role-based authorization for every authenticated `/api` route, plus:
/// - transfer checks (editor on both sides; no peer leaks),
/// - optimistic concurrency (`If-Match` / body `version` on PATCH -> 409),
/// - an audit_log row for every successful mutation.
/// Unknown routes are denied (404). No access -> 404; too low a role -> 403.
Middleware authzMiddleware(ScopedDb db) {
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
          case Scope.stream:
            final a = await authz.stream(params['a']!, uid);
            if (a != null) {
              access =
                  Access(role: a.role, streamId: a.streamId, params: params);
            }
          case Scope.event:
            final ta = await authz.eventStreams(params['t']!);
            if (ta != null) {
              final a = await authz.stream(ta.$1, uid);
              if (a != null) {
                access = Access(
                    role: a.role,
                    streamId: a.streamId,
                    params: {...params, if (ta.$2 != null) 'peer': ta.$2!});
              }
            }
          case Scope.invite:
            final acc = await authz.inviteStream(params['i']!);
            final a = acc == null ? null : await authz.stream(acc, uid);
            if (a != null) {
              access = Access(role: a.role, streamId: acc, params: params);
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

          // Transfers: editor on the target stream, and on the existing
          // peer of a linked row being changed.
          final to = body?['transferToStreamId'];
          if (to != null) {
            final t = await authz.stream('$to', uid);
            if (t == null) return jsonError(404, 'transfer stream not found');
            if (!t.role!.atLeast(Role.editor)) {
              return jsonError(403, 'requires editor role on transfer stream');
            }
          }
          final peer = access.params['peer'];
          if (policy.scope == Scope.event && peer != null) {
            final p = await authz.stream(peer, uid);
            if (p == null || !p.role!.atLeast(Role.editor)) {
              return jsonError(
                  403, 'requires editor role on the linked transfer stream');
            }
          }
        }

        Future<Response> handle() async {
          // Optimistic concurrency, checked under a row lock.
          if (mutating && policy.versioned != null) {
            final expected = _expectedVersion(request, body);
            if (expected != null) {
              final v = await _lockVersion(db, policy.versioned!, params);
              if (v != null && v != expected) {
                final current = await _current(db, policy.versioned!, params);
                final redacted =
                    await _redact(authz, uid, current) as Map<String, dynamic>?;
                return jsonError(409, 'version conflict',
                        details: {'current': redacted})
                    .change(headers: {'x-conflict': 'version'});
              }
            }
          }

          final res = await inner(request.change(context: {'access': access}));

          // Peer redaction on JSON that may contain transfer links; and the
          // JSON body for the audit row.
          var out = res;
          Map<String, dynamic>? resJson;
          if ((res.headers['content-type'] ?? '').contains('json')) {
            final text = await res.readAsString();
            Object? decoded;
            try {
              decoded = jsonDecode(text);
            } catch (_) {}
            if (decoded is Map<String, dynamic>) resJson = decoded;
            if ((rest[0] == 'streams' || rest[0] == 'events') &&
                (text.contains('"peerStreamId"') ||
                    text.contains('"offsetStreamIds":["'))) {
              out = res.change(
                  body: jsonEncode(await _redact(authz, uid, decoded)));
            } else {
              out = res.change(body: text);
            }
          }

          final success = res.statusCode >= 200 && res.statusCode < 300;
          if (mutating && !success) throw RollbackWith<Response>(out);
          if (mutating && policy.event != null) {
            await audit.recordRequest(
              userId: uid,
              policy: policy,
              access: access!,
              params: params,
              createdId: resJson?['id']?.toString(),
              response: resJson,
              clientId: request.headers['x-client-id'],
            );
          }
          return out;
        }

        if (!mutating) return handle();
        // The handler's writes, its audit row and its NOTIFY commit together.
        try {
          return await db.runInRequestTx(handle);
        } on RollbackWith<Response> catch (e) {
          return e.value;
        }
      };
}

Future<int?> _lockVersion(
    Session db, String table, Map<String, String> p) async {
  final id = switch (table) {
    'streams' => p['a'],
    'events' => p['t'],
    'scenarios' => p['s'],
    _ => null,
  };
  if (id == null || !uuidRe.hasMatch(id)) return null;
  final r = await db.execute(
    Sql.named('SELECT version FROM $table WHERE id = @id::uuid FOR UPDATE'),
    parameters: {'id': id},
  );
  return r.isEmpty ? null : r.first[0] as int;
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
    case 'streams':
      json = (await StreamRepo(db).get(p['a']!))?.toJson();
    case 'events':
      json = (await EventRepo(db).get(p['t']!))?.toJson();
    case 'scenarios':
      final s = await ScenarioRepo(db).get(p['s']!);
      json = s != null && s.streamId == p['a'] ? s.toJson() : null;
  }
  return json == null
      ? null
      : jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
}

/// Nulls peer stream names on transfer links whose
/// peer stream the user cannot read; marks them `peerReadable: false`.
Future<Object?> _redact(Authz authz, String uid, Object? json) async {
  final links = <Map<String, dynamic>>[];
  void walk(Object? n) {
    if (n is Map<String, dynamic>) {
      if (n.containsKey('peerStreamId')) links.add(n);
      n.values.forEach(walk);
    } else if (n is List) {
      n.forEach(walk);
    }
  }

  walk(json);
  await _redactOffsets(authz, uid, json);
  if (links.isEmpty) return json;
  final ids = links.map((l) => l['peerStreamId']).whereType<String>();
  final readable = await authz.readableStreams(ids, uid);
  for (final l in links) {
    final id = l['peerStreamId'];
    final ok = id == null || readable.contains(id);
    l['peerReadable'] = ok;
    if (!ok) {
      l['peerStreamName'] = null;
    }
  }
  return json;
}

/// Spec 004 rule 5: a loan's offset stream ids the user cannot read are
/// dropped from `offsetStreamIds`, and `offsetHidden: true` says a link is
/// there ("Linked offset account (not shared with you)").
Future<void> _redactOffsets(Authz authz, String uid, Object? json) async {
  final nodes = <Map<String, dynamic>>[];
  void walk(Object? n) {
    if (n is Map<String, dynamic>) {
      final o = n['offsetStreamIds'];
      if (o is List && o.isNotEmpty) nodes.add(n);
      n.values.forEach(walk);
    } else if (n is List) {
      n.forEach(walk);
    }
  }

  walk(json);
  if (nodes.isEmpty) return;
  final ids = {
    for (final n in nodes) ...(n['offsetStreamIds'] as List).whereType<String>()
  };
  final readable = await authz.readableStreams(ids, uid);
  for (final n in nodes) {
    final list = (n['offsetStreamIds'] as List).whereType<String>().toList();
    final kept = [
      for (final id in list)
        if (readable.contains(id)) id
    ];
    if (kept.length != list.length) {
      n['offsetStreamIds'] = kept;
      n['offsetHidden'] = true;
    }
  }
}
