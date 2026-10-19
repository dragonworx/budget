import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:postgres/postgres.dart';

import 'event.dart';
import 'event_bus.dart';

/// A dedicated Postgres connection that LISTENs on [BudgetEvent.channel] and
/// publishes each notification to [bus]. Reconnects with backoff (1 s .. 30 s)
/// and signals a gap after every reconnect so subscribers re-read audit_log.
class PgListener {
  PgListener(this._open, this.bus, {this.onLog});

  final Future<Connection> Function() _open;
  final EventBus bus;
  final void Function(String)? onLog;

  Connection? _conn;
  bool _stopped = false;
  final _ready = Completer<void>();
  int _failures = 0;

  /// Completes once the first LISTEN is active.
  Future<void> get ready => _ready.future;
  bool get connected => _conn != null;

  void start() => unawaited(_loop());

  Future<void> _loop() async {
    var first = true;
    while (!_stopped) {
      try {
        final conn = await _open();
        _conn = conn;
        final sub = conn.channels[BudgetEvent.channel].listen((payload) {
          try {
            bus.publish(BudgetEvent.fromJson(
                jsonDecode(payload) as Map<String, dynamic>));
          } catch (e) {
            onLog?.call('realtime: bad payload ignored: $e');
          }
        });
        // Make sure LISTEN is registered before declaring readiness.
        await conn.execute('LISTEN ${BudgetEvent.channel}');
        _failures = 0;
        if (first) {
          first = false;
          if (!_ready.isCompleted) _ready.complete();
        } else {
          onLog?.call('realtime: listener reconnected');
          bus.gap();
        }
        await conn.closed;
        await sub.cancel();
      } catch (e) {
        onLog?.call('realtime: listener error: $e');
      }
      _conn = null;
      if (_stopped) break;
      _failures++;
      final wait = Duration(
          milliseconds:
              min(30000, 1000 * pow(2, min(_failures - 1, 5)).toInt()));
      await Future<void>.delayed(wait);
      // A reconnect after a drop is a potential gap even if the next
      // connect fails; subscribers will also catch up on success.
    }
  }

  /// Test hook: drop the connection to exercise reconnect.
  Future<void> dropConnection() async => _conn?.close(force: true);

  Future<void> stop() async {
    _stopped = true;
    await _conn?.close(force: true);
  }
}
