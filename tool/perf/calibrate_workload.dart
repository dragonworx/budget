// Fixed CPU workload for tool/perf/calibrate.mjs (spec 005 clarification).
// Deterministic: the same work every run, so its time on the box can be
// compared with the reference phones later (audit §5). Not used by the app.
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;

@JS('__calibrateDone')
external void _done(JSNumber ms, JSString checksum);

void main() {
  final sw = Stopwatch()..start();
  var check = 0;
  // 1. JSON round trip of a balance-like payload (~2 MB).
  final rnd = math.Random(42);
  final days = [
    for (var i = 0; i < 20000; i++)
      {
        'd': '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
        'b': rnd.nextDouble() * 1e5,
        'o': i % 7,
      },
  ];
  final text = jsonEncode(days);
  final back = jsonDecode(text) as List;
  check += back.length + text.length;
  // 2. Sorting and binary searches over doubles.
  final xs = [for (var i = 0; i < 200000; i++) rnd.nextDouble() * 1e6]..sort();
  for (var i = 0; i < 200000; i++) {
    final t = rnd.nextDouble() * 1e6;
    var lo = 0, hi = xs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (xs[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    check += lo & 1;
  }
  // 3. Map-heavy string work (label-cache-like).
  final m = <String, int>{};
  for (var i = 0; i < 300000; i++) {
    final k = 'k${i % 5000}';
    m[k] = (m[k] ?? 0) + i;
  }
  check += m.length;
  _done((sw.elapsedMicroseconds / 1000.0).toJS, '$check'.toJS);
}
