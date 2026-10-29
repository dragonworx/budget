import 'package:postgres/postgres.dart';

/// Roles, ordered: viewer < editor < owner.
enum Role {
  viewer,
  editor,
  owner;

  static Role? parse(Object? v) {
    if (v == null) return null;
    for (final r in Role.values) {
      if (r.name == v.toString()) return r;
    }
    return null;
  }

  bool atLeast(Role other) => index >= other.index;
  static Role? max(Role? a, Role? b) =>
      a == null ? b : (b == null ? a : (a.index >= b.index ? a : b));
}

/// What a resolved request may do, attached as `request.context['access']`.
class Access {
  Access({
    this.role,
    this.streamId,
    this.params = const {},
  });

  /// Effective role on the target (null for scope `auth`/`admin`): owner
  /// for the stream's owner, else the stream share's role.
  final Role? role;
  final String? streamId;
  final Map<String, String> params;

  bool get isOwner => role == Role.owner;
}

/// How a route's target is resolved to a role.
enum Scope {
  /// Any signed-in user; no resource.
  auth,

  /// Admin users only.
  admin,

  /// `:a`: owner if the user owns it, else their stream share's role.
  stream,

  /// `:t` via its stream.
  event,

  /// `:i` (invite id) via the invite's stream.
  invite,
}

class Policy {
  const Policy(this.method, this.path, this.scope,
      {this.min = Role.viewer, this.event, this.versioned});

  final String method;

  /// Path below `/api/`, `:x` segments are parameters.
  final String path;
  final Scope scope;
  final Role min;

  /// Audit/realtime action name for mutations (e.g. `event.updated`).
  final String? event;

  /// Table whose `version` a PATCH must match (optimistic concurrency).
  final String? versioned;

  List<String> get segments => path.split('/');

  Map<String, String>? match(String m, List<String> segs) {
    if (m != method && !(m == 'HEAD' && method == 'GET')) return null;
    final p = segments;
    if (p.length != segs.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < p.length; i++) {
      if (p[i].startsWith(':')) {
        if (segs[i].isEmpty) return null;
        params[p[i].substring(1)] = segs[i];
      } else if (p[i] != segs[i]) {
        return null;
      }
    }
    return params;
  }
}

const _e = Role.editor, _o = Role.owner;

/// Every authenticated `/api` route. Anything not listed is denied (404);
/// `test/authz/route_sweep_test.dart` checks each router route has an entry.
const policies = <Policy>[
  // Streams
  Policy('GET', 'streams', Scope.auth),
  Policy('POST', 'streams', Scope.auth, event: 'stream.created'),
  Policy('GET', 'streams/:a', Scope.stream),
  // Remember the last-opened stream (landing after sign-in). No event.
  Policy('POST', 'streams/:a/opened', Scope.stream),
  // The caller's own saved timeline view (no event: not audited/broadcast).
  Policy('GET', 'streams/:a/view', Scope.stream),
  Policy('PUT', 'streams/:a/view', Scope.stream),
  Policy('PATCH', 'streams/:a', Scope.stream,
      min: _e, event: 'stream.updated', versioned: 'streams'),
  Policy('DELETE', 'streams/:a', Scope.stream,
      min: _o, event: 'stream.deleted'),
  Policy('GET', 'streams/:a/events', Scope.stream),
  Policy('POST', 'streams/:a/events', Scope.stream,
      min: _e, event: 'event.created'),
  Policy('POST', 'streams/:a/events/import', Scope.stream,
      min: _e, event: 'events.imported'),
  // Undo of an import: bulk delete of the ids that import created.
  Policy('POST', 'streams/:a/events/import/undo', Scope.stream,
      min: _e, event: 'events.import_undone'),
  // The day pick's ✂ (end every event on a day) and its Undo.
  Policy('POST', 'streams/:a/events/trim', Scope.stream,
      min: _e, event: 'events.trimmed'),
  Policy('POST', 'streams/:a/events/trim/undo', Scope.stream,
      min: _e, event: 'events.trim_undone'),
  Policy('PATCH', 'streams/:a/reorder-events', Scope.stream,
      min: _e, event: 'stream.reordered'),
  Policy('GET', 'streams/:a/categories', Scope.stream),
  Policy('POST', 'streams/:a/categories', Scope.stream,
      min: _e, event: 'category.created'),
  Policy('PATCH', 'streams/:a/categories/:c', Scope.stream,
      min: _o, event: 'category.updated'),
  Policy('GET', 'streams/:a/categories/:c/delete-preview', Scope.stream),
  Policy('DELETE', 'streams/:a/categories/:c', Scope.stream,
      min: _o, event: 'category.deleted'),
  Policy('DELETE', 'streams/:a/categories/:c/events', Scope.stream,
      min: _o, event: 'category.events_deleted'),
  Policy('GET', 'streams/:a/balance', Scope.stream),
  Policy('POST', 'streams/:a/project', Scope.stream),
  Policy('GET', 'streams/:a/insights', Scope.stream),
  Policy('POST', 'streams/:a/solve', Scope.stream),
  Policy('POST', 'streams/:a/goal', Scope.stream),
  Policy('GET', 'streams/:a/scenarios', Scope.stream),
  Policy('POST', 'streams/:a/scenarios', Scope.stream,
      min: _e, event: 'scenario.created'),
  Policy('PATCH', 'streams/:a/scenarios/:s', Scope.stream,
      min: _e, event: 'scenario.updated', versioned: 'scenarios'),
  Policy('DELETE', 'streams/:a/scenarios/:s', Scope.stream,
      min: _e, event: 'scenario.deleted'),
  // Stream sharing
  Policy('GET', 'streams/:a/shares', Scope.stream),
  Policy('POST', 'streams/:a/invites', Scope.stream,
      min: _o, event: 'invite.created'),
  Policy('PATCH', 'streams/:a/shares/:u', Scope.stream,
      min: _o, event: 'stream_share.changed'),
  Policy('DELETE', 'streams/:a/shares/:u', Scope.stream,
      min: _o, event: 'stream_share.revoked'),
  Policy('POST', 'streams/:a/leave', Scope.stream, event: 'stream_share.left'),
  // Events
  Policy('GET', 'events/:t', Scope.event),
  Policy('PATCH', 'events/:t', Scope.event,
      min: _e, event: 'event.updated', versioned: 'events'),
  Policy('DELETE', 'events/:t', Scope.event, min: _e, event: 'event.deleted'),
  Policy('PUT', 'events/:t/skips/:d', Scope.event,
      min: _e, event: 'skip.changed'),
  Policy('PUT', 'events/:t/overrides/:d', Scope.event,
      min: _e, event: 'event.override_set', versioned: 'events'),
  Policy('DELETE', 'events/:t/overrides/:d', Scope.event,
      min: _e, event: 'event.override_cleared', versioned: 'events'),
  Policy('DELETE', 'events/:t/overrides', Scope.event,
      min: _e, event: 'event.overrides_cleared', versioned: 'events'),
  Policy('POST', 'events/:t/split', Scope.event,
      min: _e, event: 'event.split', versioned: 'events'),
  // Invites
  Policy('GET', 'invites', Scope.auth),
  Policy('POST', 'invites/preview', Scope.auth),
  Policy('POST', 'invites/accept', Scope.auth, event: 'invite.accepted'),
  Policy('POST', 'invites/:i/link', Scope.invite,
      min: _o, event: 'invite.link_rotated'),
  Policy('DELETE', 'invites/:i', Scope.invite,
      min: _o, event: 'invite.revoked'),
  // Realtime (SSE; per-change filtering happens in the live connection)
  Policy('GET', 'live', Scope.auth),
  // Deprecated SSE path from before the Streams/Events rename (old tabs).
  Policy('GET', 'events', Scope.auth),
  // Admin
  Policy('GET', 'admin/users', Scope.admin),
  Policy('PATCH', 'admin/users/:u', Scope.admin, event: 'admin.user_updated'),
  Policy('GET', 'admin/allowlist', Scope.admin),
  Policy('POST', 'admin/allowlist', Scope.admin,
      event: 'admin.allowlist_added'),
  Policy('DELETE', 'admin/allowlist/:pattern', Scope.admin,
      event: 'admin.allowlist_removed'),
];

/// Finds the policy for `METHOD /api/<segs>`; null means deny.
(Policy, Map<String, String>)? findPolicy(String method, List<String> segs) {
  for (final p in policies) {
    final m = p.match(method, segs);
    if (m != null) return (p, m);
  }
  return null;
}

final uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false);

/// Role lookups (one query each).
class Authz {
  Authz(this._db);
  final Session _db;

  /// Effective access to a stream: owner, else its share role.
  Future<Access?> stream(String streamId, String userId) async {
    if (!uuidRe.hasMatch(streamId)) return null;
    final r = await _db.execute(
      Sql.named('''
        SELECT CASE WHEN a.owner_id = @u::uuid THEN 'owner'
                    ELSE s.role::text END
        FROM streams a
        LEFT JOIN stream_shares s
          ON s.stream_id = a.id AND s.user_id = @u::uuid
        WHERE a.id = @a::uuid
      '''),
      parameters: {'a': streamId, 'u': userId},
    );
    if (r.isEmpty) return null;
    final role = Role.parse(r.first[0]);
    if (role == null) return null;
    return Access(role: role, streamId: streamId);
  }

  /// Streams (of [ids]) that [userId] can read.
  Future<Set<String>> readableStreams(
      Iterable<String> ids, String userId) async {
    final list = ids.where(uuidRe.hasMatch).toSet().toList();
    if (list.isEmpty) return {};
    final r = await _db.execute(
      Sql.named('''
        SELECT a.id::text FROM streams a
        WHERE a.id = ANY (@ids::uuid[]) AND (
          a.owner_id = @u::uuid
          OR EXISTS (SELECT 1 FROM stream_shares s
                  WHERE s.stream_id = a.id AND s.user_id = @u::uuid))
      '''),
      parameters: {'ids': list, 'u': userId},
    );
    return {for (final row in r) row[0] as String};
  }

  /// (streamId, peer streamId?) for an event.
  Future<(String, String?)?> eventStreams(String txId) async {
    if (!uuidRe.hasMatch(txId)) return null;
    final r = await _db.execute(
      Sql.named('''
        SELECT t.stream_id::text, p.stream_id::text FROM events t
        LEFT JOIN events p ON t.transfer_id IS NOT NULL
          AND p.transfer_id = t.transfer_id AND p.id <> t.id
        WHERE t.id = @t::uuid
      '''),
      parameters: {'t': txId},
    );
    if (r.isEmpty) return null;
    return (r.first[0] as String, r.first[1] as String?);
  }

  /// The stream an invite targets.
  Future<String?> inviteStream(String inviteId) async {
    if (!uuidRe.hasMatch(inviteId)) return null;
    final r = await _db.execute(
      Sql.named('SELECT stream_id::text FROM invites WHERE id = @i::uuid'),
      parameters: {'i': inviteId},
    );
    return r.isEmpty ? null : r.first[0] as String?;
  }
}
