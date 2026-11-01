// Perf instrumentation (spec 005 R3). Timeline marks around the chart's
// build / paint phases and the balance decode, compiled in only for
// profile / debug builds or `--dart-define=PERF_HUD=true` (a release build
// without the define is unchanged: [perfMarksEnabled] is a const false
// and the calls fold away).
//
// With PERF_HUD the app also shows Flutter's performance overlay and a small
// HUD (frame p50 / p95 / max from SchedulerBinding timings, and the chart's
// own paint time), and on the web exposes `window.__budgiePerf` for the
// benchmark (tool/perf/pan_35y.mjs): {p50, p95, max, frames, paintP50,
// paintP95, paintMax, raf: {p50, p95, p99, max, n}, longTasks: {count,
// totalMs, maxMs}, heapMB, latency: {p50, p95, max, n}, reset(),
// snapshot()}. Fields refresh about twice a second; snapshot() recomputes.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'perf_hud_stub.dart'
    if (dart.library.js_interop) 'perf_hud_web.dart'
    as platform;

/// `--dart-define=PERF_HUD=true`: the HUD, overlay and `__budgiePerf`.
const bool kPerfHud = bool.fromEnvironment('PERF_HUD');

/// Timeline marks are recorded (never in a plain release build).
const bool perfMarksEnabled = kProfileMode || kDebugMode || kPerfHud;

/// Starts a Timeline mark named [name] (end it with [perfFinish]).
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
void perfStart(String name) {
  if (perfMarksEnabled) {
    developer.Timeline.startSync(name);
    if (debugPerfSectionUs != null) {
      _sections.add((name, Stopwatch()..start()));
    }
  }
}

/// Test hook (benchmarks): when set, total microseconds per mark name.
@visibleForTesting
Map<String, int>? debugPerfSectionUs;

final _sections = <(String, Stopwatch)>[];

/// Ends the innermost [perfStart] mark.
@pragma('vm:prefer-inline')
@pragma('dart2js:tryInline')
void perfFinish() {
  if (perfMarksEnabled) {
    developer.Timeline.finishSync();
    final totals = debugPerfSectionUs;
    if (totals != null && _sections.isNotEmpty) {
      final (name, sw) = _sections.removeLast();
      totals[name] = (totals[name] ?? 0) + sw.elapsedMicroseconds;
    }
  }
}

double _pct(List<double> sorted, double p) => sorted.isEmpty
    ? 0
    : sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

double _round(double v) => (v * 10).roundToDouble() / 10;

/// Frame and paint samples since the last [reset].
class PerfStats {
  PerfStats._();
  static final instance = PerfStats._();

  final _frames = <double>[];
  final _paints = <double>[];

  void addTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frames.add(t.totalSpan.inMicroseconds / 1000);
    }
  }

  /// The chart painter's own time for one paint, in ms.
  void addPaint(double ms) => _paints.add(ms);

  void reset() {
    _frames.clear();
    _paints.clear();
    platform.reset();
  }

  Map<String, Object?> snapshot() {
    final f = [..._frames]..sort();
    final p = [..._paints]..sort();
    return {
      'p50': _round(_pct(f, 0.5)),
      'p95': _round(_pct(f, 0.95)),
      'max': _round(f.isEmpty ? 0 : f.last),
      'frames': f.length,
      'paintP50': _round(_pct(p, 0.5)),
      'paintP95': _round(_pct(p, 0.95)),
      'paintMax': _round(p.isEmpty ? 0 : p.last),
      'paints': p.length,
      ...platform.extra(),
    };
  }
}

/// Paint stopwatch for the chart painter: null unless [kPerfHud].
Stopwatch? perfPaintStopwatch() => kPerfHud ? (Stopwatch()..start()) : null;

/// Records [sw] (from [perfPaintStopwatch]) as one chart paint.
void perfPaintDone(Stopwatch? sw) {
  if (sw != null) PerfStats.instance.addPaint(sw.elapsedMicroseconds / 1000);
}

var _installed = false;

/// Starts collecting (PERF_HUD builds only): frame timings and, on the
/// web, `window.__budgiePerf`.
void installPerfHud() {
  if (!kPerfHud || _installed) return;
  _installed = true;
  SchedulerBinding.instance.addTimingsCallback(PerfStats.instance.addTimings);
  platform.install(PerfStats.instance.snapshot, PerfStats.instance.reset);
}

/// The HUD over [child] in PERF_HUD builds; just [child] otherwise.
class PerfHud extends StatefulWidget {
  const PerfHud({super.key, required this.child});
  final Widget child;

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  Timer? _timer;
  Map<String, Object?> _s = const {};

  @override
  void initState() {
    super.initState();
    if (!kPerfHud) return;
    installPerfHud();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _s = PerfStats.instance.snapshot());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!kPerfHud) return widget.child;
    final raf = _s['raf'];
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        Positioned(
          right: 8,
          bottom: 8,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC000000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  'frame p50 ${_s['p50']} p95 ${_s['p95']} max ${_s['max']} '
                  '(${_s['frames']})\n'
                  'paint p50 ${_s['paintP50']} p95 ${_s['paintP95']} '
                  'max ${_s['paintMax']}'
                  '${raf is Map ? '\nraf p95 ${raf['p95']} max ${raf['max']}' : ''}',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Color(0xFFE0FFE0),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
