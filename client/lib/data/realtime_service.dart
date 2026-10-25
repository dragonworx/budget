import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Connection state shown by the header dot.
enum RealtimeStatus { connecting, connected, reconnecting, offline }

/// One committed change (plan §4c).
class ChangeEvent {
  const ChangeEvent({
    required this.id,
    required this.action,
    this.entity,
    this.entityId,
    this.streamId,
    this.actorId,
    this.subjectUserId,
    this.clientId,
    this.detail = const {},
  });

  final int id;
  final String action;
  final String? entity;
  final String? entityId;
  final String? streamId;
  final String? actorId;
  final String? subjectUserId;
  final String? clientId;
  final Map<String, dynamic> detail;

  String get kind => action.split('.').first;
  String? get peerStreamId => detail['peerStreamId']?.toString();
  int? get version => (detail['version'] as num?)?.toInt();

  factory ChangeEvent.fromJson(Map<String, dynamic> j) => ChangeEvent(
    id: (j['id'] as num).toInt(),
    action: (j['action'] ?? '').toString(),
    entity: j['entity']?.toString(),
    entityId: j['entityId']?.toString(),
    streamId: j['streamId']?.toString(),
    actorId: j['actorId']?.toString(),
    subjectUserId: j['subjectUserId']?.toString(),
    clientId: j['clientId']?.toString(),
    detail: j['detail'] is Map
        ? Map<String, dynamic>.from(j['detail'] as Map)
        : const {},
  );
}

/// A parsed SSE frame.
class SseFrame {
  const SseFrame({this.event = 'message', this.data = '', this.id, this.retry});
  final String event;
  final String data;
  final String? id;
  final int? retry;
}

/// Incremental `text/event-stream` parser (WHATWG rules: `field: value`,
/// `:` comments, blank line dispatches, multi-line data joined by `\n`).
class SseParser {
  final _buf = StringBuffer();
  String _event = '';
  final _data = <String>[];
  String? _id;
  int? _retry;

  /// Feeds decoded text; returns the frames completed by it.
  List<SseFrame> add(String chunk) {
    _buf.write(chunk);
    var text = _buf.toString();
    _buf.clear();
    final out = <SseFrame>[];
    while (true) {
      final i = text.indexOf(RegExp(r'\r\n|\n|\r'));
      if (i < 0) break;
      final nl = text.startsWith('\r\n', i) ? 2 : 1;
      final line = text.substring(0, i);
      text = text.substring(i + nl);
      final f = _line(line);
      if (f != null) out.add(f);
    }
    _buf.write(text);
    return out;
  }

  SseFrame? _line(String line) {
    if (line.isEmpty) {
      if (_data.isEmpty && _retry == null && _id == null) {
        _event = '';
        return null;
      }
      final f = SseFrame(
        event: _event.isEmpty ? 'message' : _event,
        data: _data.join('\n'),
        id: _id,
        retry: _retry,
      );
      _event = '';
      _data.clear();
      _id = null;
      _retry = null;
      return f;
    }
    if (line.startsWith(':')) return null;
    final c = line.indexOf(':');
    final field = c < 0 ? line : line.substring(0, c);
    var value = c < 0 ? '' : line.substring(c + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
      case 'id':
        if (!value.contains('\u0000')) _id = value;
      case 'retry':
        final n = int.tryParse(value);
        if (n != null) _retry = n;
    }
    return null;
  }
}

typedef Sleep = Future<void> Function(Duration);

/// SSE client for `GET /api/live`: resumes with Last-Event-ID / `?since`,
/// reconnects with backoff (honouring `retry:`), de-dupes by id, skips this
/// tab's own echoes, and reports goodbye / resync to its owner.
class RealtimeService {
  RealtimeService({
    required this.clientFactory,
    required this.baseUrl,
    required this.clientId,
    this.onEvent,
    this.onResync,
    this.onGoodbye,
    this.longDisconnect = const Duration(minutes: 2),
    this.maxBackoff = const Duration(seconds: 30),
    Sleep? sleep,
    DateTime Function()? now,
    Random? random,
  }) : _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
       _now = now ?? DateTime.now,
       _random = random ?? Random();

  final http.Client Function() clientFactory;
  final String baseUrl;
  final String clientId;
  void Function(ChangeEvent)? onEvent;

  /// Drop caches and refetch everything (resync / error / long disconnect).
  void Function(String reason)? onResync;

  /// Session ended or account disabled: go to sign-in, no reconnect.
  void Function(String reason)? onGoodbye;
  final Duration longDisconnect;
  final Duration maxBackoff;
  final Sleep _sleep;
  final DateTime Function() _now;
  final Random _random;

  final status = ValueNotifier<RealtimeStatus>(RealtimeStatus.offline);

  /// Highest id seen (cursor to resume from).
  int? lastEventId;
  Duration _retry = const Duration(seconds: 3);
  int _failures = 0;
  bool _running = false;
  bool _connectedOnce = false;
  DateTime? _lostAt;
  http.Client? _client;
  StreamSubscription<String>? _sub;
  Completer<void>? _streamDone;

  /// Ids already handled (bounded).
  final _seen = <int>{};
  final _seenOrder = <int>[];

  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    await _closeStream();
    status.value = RealtimeStatus.offline;
  }

  void dispose() {
    _running = false;
    _closeStream();
    status.dispose();
  }

  Future<void> _closeStream() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    _client?.close();
    _client = null;
    if (!(_streamDone?.isCompleted ?? true)) _streamDone!.complete();
  }

  Future<void> _loop() async {
    while (_running) {
      status.value = _connectedOnce
          ? RealtimeStatus.reconnecting
          : RealtimeStatus.connecting;
      var fatal = false;
      try {
        fatal = await _connectOnce();
      } catch (e) {
        debugPrint('realtime: $e');
      }
      if (!_running || fatal) break;
      _lostAt ??= _now();
      status.value = _failures >= 3
          ? RealtimeStatus.offline
          : RealtimeStatus.reconnecting;
      await _sleep(nextDelay());
      _failures++;
    }
  }

  /// Reconnect delay: the server's `retry` at first, then exponential
  /// backoff with jitter, capped at [maxBackoff].
  Duration nextDelay() {
    final base = _retry.inMilliseconds * pow(2, min(_failures, 6));
    final capped = min(base.toDouble(), maxBackoff.inMilliseconds.toDouble());
    final jitter = _failures == 0 ? 0 : _random.nextDouble() * 0.3 * capped;
    return Duration(
      milliseconds: (capped + jitter).round().clamp(
        0,
        maxBackoff.inMilliseconds,
      ),
    );
  }

  /// One connection. Returns true when it must not reconnect (goodbye/401).
  Future<bool> _connectOnce() async {
    final since = lastEventId;
    final uri = Uri.parse('$baseUrl/api/live')
        .replace(queryParameters: since == null ? null : {'since': '$since'});
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'X-Requested-With': 'budget',
        'X-Client-Id': clientId,
        if (since != null) 'Last-Event-ID': '$since',
      });
    final client = _client = clientFactory();
    final res = await client.send(req);
    if (res.statusCode == 401) {
      _running = false;
      status.value = RealtimeStatus.offline;
      onGoodbye?.call('unauthorized');
      return true;
    }
    if (res.statusCode != 200) {
      await res.stream.drain<void>().catchError((_) {});
      return false;
    }
    final parser = SseParser();
    var fatal = false;
    final done = _streamDone = Completer<void>();
    _sub = res.stream
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            for (final f in parser.add(chunk)) {
              if (_handle(f)) {
                fatal = true;
                _closeStream();
              }
            }
          },
          onError: (Object e) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    _sub = null;
    return fatal;
  }

  /// Handles one frame; true when the stream must end for good.
  bool _handle(SseFrame f) {
    if (f.retry != null) _retry = Duration(milliseconds: f.retry!);
    Map<String, dynamic> data() {
      try {
        final d = jsonDecode(f.data);
        return d is Map ? Map<String, dynamic>.from(d) : const {};
      } catch (_) {
        return const {};
      }
    }

    int? idOf(dynamic v) => v == null ? null : int.tryParse(v.toString());
    switch (f.event) {
      case 'change':
        final d = data();
        if (d['id'] == null && f.id != null) d['id'] = int.tryParse(f.id!);
        if (d['id'] == null) return false;
        final e = ChangeEvent.fromJson(d);
        _advance(e.id);
        if (!_markSeen(e.id)) return false;
        if (e.clientId != null && e.clientId == clientId) return false;
        onEvent?.call(e);
      case 'ready':
        final d = data();
        final cur = idOf(d['lastEventId']) ?? idOf(f.id);
        if (cur != null) _advance(cur);
        final lost = _lostAt;
        _lostAt = null;
        _failures = 0;
        status.value = RealtimeStatus.connected;
        if (_connectedOnce &&
            lost != null &&
            _now().difference(lost) >= longDisconnect) {
          onResync?.call('long disconnect');
        }
        _connectedOnce = true;
      case 'resync':
      case 'error':
        final d = data();
        final cur = idOf(d['lastEventId']) ?? idOf(f.id);
        if (cur != null) lastEventId = cur;
        onResync?.call((d['reason'] ?? d['error'] ?? f.event).toString());
      case 'goodbye':
        _running = false;
        status.value = RealtimeStatus.offline;
        onGoodbye?.call((data()['reason'] ?? 'session ended').toString());
        return true;
      case 'reconnect':
        // Server redeploying: reconnect promptly (retry: 1000 precedes it).
        final cur = idOf(data()['lastEventId']);
        if (cur != null) _advance(cur);
        _failures = 0;
        _closeStream();
    }
    return false;
  }

  void _advance(int id) {
    if (lastEventId == null || id > lastEventId!) lastEventId = id;
  }

  bool _markSeen(int id) {
    if (!_seen.add(id)) return false;
    _seenOrder.add(id);
    if (_seenOrder.length > 2000) _seen.remove(_seenOrder.removeAt(0));
    return true;
  }
}
