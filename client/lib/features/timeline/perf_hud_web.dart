// Web PERF_HUD hooks (spec 005 R3): window.__budgiePerf, rAF-to-rAF
// intervals, long tasks (PerformanceObserver, where supported), JS heap
// (performance.memory, Chromium) and pointer-to-presented-frame latency
// (pointer event to the second animation frame after it: the frame that
// handled it has been presented by then). Only installed in PERF_HUD
// builds.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

final _raf = <double>[];
double? _lastRaf;
final _longTasks = <double>[];
final _latency = <double>[];
double? _pointerAt;
var _framesSincePointer = 0;

double _pct(List<double> sorted, double p) => sorted.isEmpty
    ? 0
    : sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];
double _r(double v) => (v * 10).roundToDouble() / 10;

Map<String, Object?> _dist(List<double> values) {
  final s = [...values]..sort();
  return {
    'p50': _r(_pct(s, 0.5)),
    'p95': _r(_pct(s, 0.95)),
    'p99': _r(_pct(s, 0.99)),
    'max': _r(s.isEmpty ? 0 : s.last),
    'n': s.length,
  };
}

void reset() {
  _raf.clear();
  _lastRaf = null;
  _longTasks.clear();
  _latency.clear();
  _pointerAt = null;
}

Map<String, Object?> extra() {
  double? heap;
  try {
    final memory = web.window.performance.getProperty<JSObject?>('memory'.toJS);
    final used = memory?.getProperty<JSNumber?>('usedJSHeapSize'.toJS);
    if (used != null) heap = _r(used.toDartDouble / (1024 * 1024));
  } catch (_) {}
  return {
    'raf': _dist(_raf),
    'longTasks': {
      'count': _longTasks.length,
      'totalMs': _r(_longTasks.fold(0.0, (a, b) => a + b)),
      'maxMs': _r(_longTasks.fold(0.0, math.max)),
    },
    'heapMB': heap,
    'latency': _dist(_latency),
  };
}

void install(Map<String, Object?> Function() snapshot, void Function() reset) {
  void tick(JSNumber now) {
    final t = now.toDartDouble;
    final last = _lastRaf;
    if (last != null) _raf.add(t - last);
    _lastRaf = t;
    final at = _pointerAt;
    if (at != null && ++_framesSincePointer >= 2) {
      _latency.add(t - at);
      _pointerAt = null;
    }
    web.window.requestAnimationFrame(tick.toJS);
  }

  web.window.requestAnimationFrame(tick.toJS);

  void onPointer(web.Event e) {
    if (_pointerAt != null) return;
    _pointerAt = e.timeStamp;
    _framesSincePointer = 0;
  }

  final opts = web.AddEventListenerOptions(capture: true, passive: true);
  for (final type in const ['pointermove', 'pointerdown', 'wheel']) {
    web.window.addEventListener(type, onPointer.toJS, opts);
  }

  try {
    final observer = web.PerformanceObserver(
      ((web.PerformanceObserverEntryList list, web.PerformanceObserver _) {
        for (final e in list.getEntries().toDart) {
          if (e.duration > 50) _longTasks.add(e.duration);
        }
      }).toJS,
    );
    observer.observe(
      web.PerformanceObserverInit(entryTypes: ['longtask'.toJS].toJS),
    );
  } catch (_) {
    // No long-task support (WebKit): counts stay 0.
  }

  final api = JSObject();
  void publish() {
    snapshot().forEach((k, v) => api.setProperty(k.toJS, v.jsify()));
  }

  api.setProperty(
    'reset'.toJS,
    (() {
      reset();
      publish();
    }).toJS,
  );
  api.setProperty(
    'snapshot'.toJS,
    (() {
      publish();
      return snapshot().jsify();
    }).toJS,
  );
  publish();
  globalContext.setProperty('__budgiePerf'.toJS, api);
  Timer.periodic(const Duration(milliseconds: 500), (_) => publish());
}
