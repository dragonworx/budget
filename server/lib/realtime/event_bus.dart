import 'dart:async';

import 'event.dart';

/// In-process fan-out of committed change events to this replica's SSE
/// subscribers. Fed by [PgListener] (LISTEN/NOTIFY), so every replica sees
/// every event regardless of which replica handled the write.
class EventBus {
  final _events = StreamController<BudgetEvent>.broadcast(sync: true);
  final _gaps = StreamController<void>.broadcast(sync: true);
  final _shutdown = StreamController<String>.broadcast(sync: true);

  /// Server is shutting down: streams should tell clients to reconnect
  /// (to another replica) and close.
  Stream<String> get shutdowns => _shutdown.stream;
  void shutdown(String reason) => _shutdown.add(reason);

  /// Live events, in NOTIFY (commit) order.
  Stream<BudgetEvent> get events => _events.stream;

  /// Fired when delivery may have missed events (listener reconnected);
  /// subscribers should catch up from audit_log.
  Stream<void> get gaps => _gaps.stream;

  int get subscriberCount => _subscribers;
  int _subscribers = 0;
  void addSubscriber() => _subscribers++;
  void removeSubscriber() => _subscribers--;

  void publish(BudgetEvent e) => _events.add(e);
  void gap() => _gaps.add(null);

  Future<void> close() async {
    await _events.close();
    await _gaps.close();
    await _shutdown.close();
  }
}
