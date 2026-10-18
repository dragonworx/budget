import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/api_client.dart';
import 'boot_loader_stub.dart'
    if (dart.library.js_interop) 'boot_loader_web.dart'
    as impl;

/// Bridges the app to the inline HTML boot loader (window.budgetLoader).
/// No-op off the web (tests, VM).
class BootLoader {
  static bool _finished = false;

  static void stage(String name, [String? label]) => impl.stage(name, label);
  static void progress(String name, double? fraction, [String? label]) =>
      impl.progress(name, fraction, label);
  static void done([String? name]) => impl.done(name);
  static void error(String message) => impl.error(message);

  /// After the first frame, waits for the initial API requests to settle,
  /// then dismisses the loader. Call once, right after runApp.
  static void finishWhenReady({
    Duration maxWait = const Duration(seconds: 15),
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      done('frame');
      stage('data', 'Loading your data');
      final started = DateTime.now();
      var idleTicks = 0;
      Timer.periodic(const Duration(milliseconds: 50), (t) {
        if (_finished) return t.cancel();
        final s = ApiClient.stats;
        if (s.started > 0) {
          progress(
            'data',
            s.completed / s.started,
            'Loading your data (${s.completed}/${s.started})',
          );
        }
        final failure = ApiClient.firstFailure;
        if (failure != null && s.inFlight == 0 && s.completed == s.started) {
          // Let the app show its own error UI rather than blocking on the loader.
          _finish();
          return t.cancel();
        }
        // Idle = nothing in flight for ~150ms after at least one frame.
        idleTicks = s.inFlight == 0 ? idleTicks + 1 : 0;
        final waited = DateTime.now().difference(started);
        if ((idleTicks >= 3 &&
                (s.started > 0 || waited.inMilliseconds > 600)) ||
            waited > maxWait) {
          _finish();
          t.cancel();
        }
      });
    });
  }

  static void _finish() {
    if (_finished) return;
    _finished = true;
    // Wait one more frame so the data is painted before the overlay fades.
    WidgetsBinding.instance.addPostFrameCallback((_) => done());
    WidgetsBinding.instance.scheduleFrame();
  }
}
