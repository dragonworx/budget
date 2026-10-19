import 'dart:async';

import 'package:shelf/shelf.dart';

/// Tracks in-flight requests and the draining state for graceful shutdown.
class Lifecycle {
  bool _draining = false;
  int _inFlight = 0;
  Completer<void>? _idle;

  bool get draining => _draining;
  int get inFlight => _inFlight;

  /// Marks the server as draining: /ready returns 503 so the proxy stops
  /// routing new traffic here.
  void startDraining() => _draining = true;

  Middleware middleware() => (inner) => (request) async {
        _inFlight++;
        try {
          return await inner(request);
        } finally {
          _inFlight--;
          if (_inFlight == 0) _idle?.complete();
          if (_inFlight == 0) _idle = null;
        }
      };

  /// Completes when no request handler is running, or after [timeout].
  Future<bool> waitIdle(Duration timeout) async {
    if (_inFlight == 0) return true;
    _idle ??= Completer<void>();
    try {
      await _idle!.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}
