import 'dart:async';
import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/middleware.dart';
import '../auth/session_store.dart';
import '../realtime/access_set.dart';
import '../realtime/event.dart';
import '../realtime/event_bus.dart';
import 'json_helpers.dart';

class EventsSettings {
  const EventsSettings({
    this.heartbeat = const Duration(seconds: 25),
    this.retention = const Duration(hours: 24),
    this.maxReplay = 1000,
  });

  /// Comment ping + session re-validation interval.
  final Duration heartbeat;

  /// Catch-up older than this (or more than [maxReplay] events) -> `resync`.
  final Duration retention;
  final int maxReplay;
}

/// `GET /api/events` — Server-Sent Events of committed changes the user can
/// read. See docs/plan-auth-multitenant.md §4c for the contract.
Router buildEventsApi(Session db, SessionStore sessions, EventBus? bus,
    {EventsSettings settings = const EventsSettings()}) {
  final router = Router();
  router.get('/', (Request r) async {
    final auth = requireAuth(r);
    if (bus == null) return jsonError(503, 'realtime unavailable');
    final sinceRaw =
        r.headers['last-event-id'] ?? r.url.queryParameters['since'];
    final since = sinceRaw == null ? null : int.tryParse(sinceRaw.trim());
    if (sinceRaw != null && since == null) {
      return jsonError(400, 'invalid Last-Event-ID / since');
    }
    final stream = _EventStream(db, sessions, bus, auth, settings);
    await stream.start(since);
    return Response.ok(
      stream.output,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        'x-accel-buffering': 'no',
        'connection': 'keep-alive',
      },
      context: {'shelf.io.buffer_output': false},
    );
  });
  return router;
}

class _EventStream {
  _EventStream(this.db, this.sessions, this.bus, this.auth, this.settings);

  final Session db;
  final SessionStore sessions;
  final EventBus bus;
  final AuthContext auth;
  final EventsSettings settings;

  late final StreamController<List<int>> _out =
      StreamController<List<int>>(onCancel: _close);
  Stream<List<int>> get output => _out.stream;

  late AccessSet _access;
  final _subs = <StreamSubscription<Object?>>[];
  Timer? _heartbeat;
  bool _closed = false;
  int _cursor = 0;
  final _seen = <int>{};
  final _seenOrder = <int>[];

  // Events are processed strictly in order (access reloads are async).
  Future<void> _chain = Future.value();
  void _enqueue(Future<void> Function() job) {
    _chain = _chain.then((_) => _closed ? null : job()).catchError((Object e) {
      _send('error', {'error': 'internal'});
    });
  }

  String get _uid => auth.user.id;

  Future<void> start(int? since) async {
    bus.addSubscriber();
    _access = await AccessSet.load(db, _uid);
    _write('retry: 3000\n\n');
    // Subscribe first so nothing committed during catch-up is missed;
    // the queue holds live events until catch-up has run.
    _subs.add(bus.events.listen((e) => _enqueue(() => _handle(e))));
    _subs.add(bus.gaps.listen((_) => _enqueue(() => _catchUp(_cursor))));
    if (since == null) {
      _enqueue(() async {
        final max = await _maxId();
        _cursor = max;
        _send('ready', {'lastEventId': max, 'userId': _uid}, id: max);
      });
    } else {
      _enqueue(() async {
        await _catchUp(since);
        _send('ready', {'lastEventId': _cursor, 'userId': _uid}, id: _cursor);
      });
    }
    _heartbeat = Timer.periodic(settings.heartbeat, (_) => _ping());
  }

  Future<int> _maxId() async {
    final r = await db.execute('SELECT COALESCE(max(id), 0) FROM audit_log');
    return (r.first[0] as num).toInt();
  }

  Future<void> _catchUp(int from) async {
    final max = await _maxId();
    if (from > max) return _resync(max, 'cursor ahead of the log');
    final rows = await db.execute(
      Sql.named('SELECT ${BudgetEvent.columns} FROM audit_log '
          'WHERE id > @f ORDER BY id LIMIT @n'),
      parameters: {'f': from, 'n': settings.maxReplay + 1},
    );
    if (rows.length > settings.maxReplay) {
      return _resync(max, 'too many missed events');
    }
    final events = rows.map(BudgetEvent.fromRow).toList();
    if (events.isNotEmpty &&
        events.first.at
            .isBefore(DateTime.now().toUtc().subtract(settings.retention))) {
      return _resync(max, 'missed events are too old');
    }
    if (_cursor < from) _cursor = from;
    for (final e in events) {
      await _handle(e);
    }
  }

  Future<void> _resync(int max, String reason) async {
    _access = await AccessSet.load(db, _uid);
    _cursor = max;
    _send('resync', {'lastEventId': max, 'reason': reason}, id: max);
  }

  Future<void> _handle(BudgetEvent e) async {
    if (_closed || _seen.contains(e.id)) return;
    _markSeen(e.id);
    var delivered = false;
    if (_access.canRead(e)) {
      _deliver(e);
      delivered = true;
    }
    final affectsMe = e.subjectUserId == _uid || e.actorId == _uid;
    if (e.changesAccess && (affectsMe || _access.touches(e))) {
      _access = await AccessSet.load(db, _uid);
      if (!delivered && _access.canRead(e)) _deliver(e);
      if (_access.disabled) return _goodbye('account disabled');
    }
  }

  void _markSeen(int id) {
    _seen.add(id);
    _seenOrder.add(id);
    if (_seenOrder.length > 5000) _seen.remove(_seenOrder.removeAt(0));
    if (id > _cursor) _cursor = id;
  }

  void _deliver(BudgetEvent e) => _send('change', e.toJson(), id: e.id);

  Future<void> _ping() async {
    if (_closed) return;
    _write(': ping\n\n');
    final info = await sessions.lookup(auth.token);
    if (info == null) await _goodbye('session ended');
  }

  Future<void> _goodbye(String reason) async {
    if (_closed) return;
    _send('goodbye', {'reason': reason});
    await _close();
    await _out.close();
  }

  void _send(String event, Object data, {int? id}) {
    _write('${id != null ? 'id: $id\n' : ''}event: $event\n'
        'data: ${jsonEncode(data)}\n\n');
  }

  void _write(String s) {
    if (!_closed && !_out.isClosed) _out.add(utf8.encode(s));
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    bus.removeSubscriber();
  }
}
