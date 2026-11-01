// Timeline pan benchmark (spec 005): pumps BalanceChart at 1600x900 while
// panning a 35-year view about 1px per frame, 20 frames, and reports the
// median / p95 frame (debug JIT in flutter_tester: compare runs, not
// absolute ms). Tagged `perf`, so it is excluded from the default run:
//
//   flutter test --run-skipped --tags perf test/perf/pan_bench_test.dart
//   NS=5000,50000 flutter test --run-skipped --tags perf test/perf/pan_bench_test.dart
//
// Data matches the audit's scratch bench (perf-audit-timeline.md §2):
// n=5000 is one daily event (13.5k occurrences), n=50000 four (54k).
@Tags(['perf'])
library;

import 'dart:io';

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/perf_hud.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _view0 = DateTime(2026, 11, 1);
const _visible = 12785.0;

BudgetEvent _ev(String id, int i) => BudgetEvent(
  id: id,
  streamId: 's',
  name: 'Event $i',
  direction: i % 3 == 0 ? EventDirection.credit : EventDirection.debit,
  amount: Decimal.fromInt(5 + (i * 37) % 400),
  startDate: _view0,
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.days,
  endMode: EndMode.never,
);

({
  BalanceSeries s,
  Map<String, String> names,
  Map<String, BudgetEvent> evs,
  List<String> order,
})
synth(int n) {
  final start = _view0.subtract(const Duration(days: 365));
  final days = _visible.toInt() + 730;
  final e = (n / _visible).ceil();
  final names = <String, String>{}, evs = <String, BudgetEvent>{};
  for (var i = 0; i < e; i++) {
    names['e$i'] = 'Event $i';
    evs['e$i'] = _ev('e$i', i);
  }
  final occ = <Occurrence>[];
  final pts = <BalancePoint>[];
  var bal = 25000 * 100;
  for (var d = 0; d < days; d++) {
    final date = DateTime(start.year, start.month, start.day + d);
    for (var i = 0; i < e; i++) {
      if (((d * 31 + i * 17) % e) * _visible >= n) continue; // thin to ~n
      final cents =
          (i % 3 == 0 ? 1 : -1) *
          (500 + (i * 3700) % 40000) ~/
          (i % 3 == 0 ? 1 : 2);
      bal += cents;
      occ.add(
        Occurrence(
          eventId: 'e$i',
          date: date,
          signedDelta: Decimal.fromInt(cents).shift(-2),
        ),
      );
    }
    pts.add(
      BalancePoint(date: date, closingBalance: Decimal.fromInt(bal).shift(-2)),
    );
  }
  return (
    s: BalanceSeries(points: pts, occurrences: occ),
    names: names,
    evs: evs,
    order: names.keys.toList(),
  );
}

void main() {
  final ns = (Platform.environment['NS'] ?? '5000,50000')
      .split(',')
      .map(int.parse);
  final out = Platform.environment['BENCH_OUT'];
  // SIZES=1600x900,390x844 (logical px, DPR 1 in flutter_tester).
  final sizes = (Platform.environment['SIZES'] ?? '1600x900').split(',').map((
    s,
  ) {
    final [w, h] = s.split('x').map(double.parse).toList();
    return Size(w, h);
  });
  for (final size in sizes) {
    for (final lanes in [false, true]) {
      for (final n in ns) {
        final w = size.width.toInt();
        testWidgets('pan 35y n=$n lanes=$lanes w=$w', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final d = synth(n);
          var viewStart = _view0;
          Widget build() => MaterialApp(
            home: Scaffold(
              body: SizedBox.fromSize(
                size: size,
                child: BalanceChart(
                  series: d.s,
                  seedDate: _view0.subtract(const Duration(days: 365)),
                  viewStart: viewStart,
                  visibleDays: _visible,
                  eventNames: d.names,
                  events: lanes ? d.evs : const {},
                  laneOrder: lanes ? d.order : const [],
                  onViewportChanged: (_, _) {},
                  onCreateOnDay: (_) {},
                ),
              ),
            ),
          );
          final sw = Stopwatch()..start();
          await tester.pumpWidget(build());
          final first = sw.elapsedMicroseconds / 1000;
          final sections = debugPerfSectionUs = <String, int>{};
          addTearDown(() => debugPerfSectionUs = null);
          final t = <double>[];
          var maxLayouts = 0, maxCandidates = 0, newPainters = 0;
          for (var i = 1; i <= 20; i++) {
            // About 1px per frame.
            viewStart = _view0.add(Duration(days: i * (_visible / w).ceil()));
            final before = debugTextPainterConstructions;
            sw.reset();
            await tester.pumpWidget(build());
            t.add(sw.elapsedMicroseconds / 1000);
            newPainters += debugTextPainterConstructions - before;
            if (!lanes && debugVertexLabelLayouts > maxLayouts) {
              maxLayouts = debugVertexLabelLayouts;
            }
            if (!lanes && debugVertexLabelCandidates > maxCandidates) {
              maxCandidates = debugVertexLabelCandidates;
            }
          }
          final perFrame = [
            for (final e in sections.entries)
              '${e.key}=${(e.value / 20000).toStringAsFixed(1)}',
          ].join(' ');
          debugPerfSectionUs = null;
          // The same pan again: every label text has been seen, so no frame
          // lays out a new TextPainter.
          final replayFrom = debugTextPainterConstructions;
          for (var i = 1; i <= 20; i++) {
            viewStart = _view0.add(Duration(days: i * (_visible / w).ceil()));
            await tester.pumpWidget(build());
          }
          final replayPainters = debugTextPainterConstructions - replayFrom;
          t.sort();
          final line =
              'w=$w n=$n occ=${d.s.occurrences.length} events=${d.names.length} '
              'lanes=$lanes first=${first.toStringAsFixed(0)}ms '
              'median=${t[10].toStringAsFixed(1)}ms '
              'p95=${t[18].toStringAsFixed(1)}ms '
              'max=${t.last.toStringAsFixed(1)}ms '
              'labelLayouts/frame<=$maxLayouts '
              'labelCandidates/frame<=$maxCandidates '
              'newPainters(20 frames)=$newPainters '
              'replayNewPainters=$replayPainters '
              'ms/frame: $perFrame';
          stdout.writeln(line);
          if (out != null) {
            File(out).writeAsStringSync('$line\n', mode: FileMode.append);
          }
          expect(maxLayouts, lessThanOrEqualTo(200));
          expect(replayPainters, 0);
        }, timeout: const Timeout(Duration(minutes: 60)));
      }
    }
  }
}
