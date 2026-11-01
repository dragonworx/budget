// Envelope parity (spec 006 tests): the coarse tiers' M4 step envelope
// draws the same balance line as the full per-day drawing. For 35y, 10y
// and 5y at 1600, 1280 and 390 px (390 at DPR 3) the series layer is
// rendered both ways (`debugLodDisabled` keeps the old path) and the
// line's pixels are compared column by column: the topmost and lowest
// line rows of the whole plot match exactly (no extreme is lost), and
// every column's top / bottom line row matches within 1 px displacement.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/lod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/synthetic_series.dart';

final _seed = DateTime(2100, 1, 1);

class _Img {
  _Img(this.w, this.h, this.rgba);
  final int w, h;
  final Uint8List rgba;

  bool line(int x, int y) {
    final i = (y * w + x) * 4;
    // Bright = the line (either colour, or their antialiased blend); the
    // background, grid and faint fills stay dark.
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    return r > 140 || g > 140 || b > 140;
  }

  /// Per column: (top, bottom) line rows inside [plot] rows, or null.
  List<(int, int)?> extents(int top, int bottom) => [
    for (var x = 0; x < w; x++)
      () {
        int? t, b;
        for (var y = top; y < bottom; y++) {
          if (line(x, y)) {
            t ??= y;
            b = y;
          }
        }
        return t == null ? null : (t, b!);
      }(),
  ];
}

Future<_Img> _render(
  WidgetTester tester,
  SynthStream s, {
  required Size size,
  required double dpr,
  required DateTime viewStart,
  required double days,
  required bool full,
}) async {
  debugLodDisabled = full;
  debugSeriesFillDisabled = true;
  addTearDown(() {
    debugLodDisabled = false;
    debugSeriesFillDisabled = false;
  });
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const ValueKey('parity'),
            child: SizedBox.fromSize(
              size: size,
              child: BalanceChart(
                // The series layer only: no dots, labels or opening vertex.
                series: BalanceSeries(points: s.series.points),
                seedDate: s.seedDate,
                lossThreshold: s.lossThreshold,
                viewStart: viewStart,
                visibleDays: days,
                eventNames: const {},
                onViewportChanged: (_, _) {},
                onCreateOnDay: (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  final ro = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('parity')),
  );
  final img = (await tester.runAsync(() => ro.toImage(pixelRatio: dpr)))!;
  final data = (await tester.runAsync(
    () => img.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final out = _Img(img.width, img.height, data.buffer.asUint8List());
  if (const bool.fromEnvironment('PARITY_DUMP')) {
    final png = (await tester.runAsync(
      () => img.toByteData(format: ui.ImageByteFormat.png),
    ))!;
    await tester.runAsync(
      () =>
          File('/tmp/parity_${size.width.toInt()}_${days.toInt()}_$full.png')
              .writeAsBytes(png.buffer.asUint8List()),
    );
  }
  return out;
}

void main() {
  final s = syntheticStream(
    id: 'al',
    name: 'Alerts',
    seedDate: _seed,
    mix: perfMixes['PERF 50k']!,
    seed: 5,
  );
  for (final (w, dpr) in const [(1600.0, 1.0), (1280.0, 1.0), (390.0, 3.0)]) {
    for (final (zoom, days) in const [
      ('35y', 12785.0),
      ('10y', 3652.0),
      ('5y', 1826.0),
    ]) {
      testWidgets('envelope parity $zoom at ${w.toInt()}px', (tester) async {
        final size = Size(w, w == 390 ? 844 : 900);
        tester.view.physicalSize = size * dpr;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.reset);
        final start = _seed.add(const Duration(days: 200));
        expect(
          lodTierOf(ChartLayout.of(size, days).plot.width / days).coarse,
          isTrue,
        );
        final full = await _render(
          tester,
          s,
          size: size,
          dpr: dpr,
          viewStart: start,
          days: days,
          full: true,
        );
        final m4 = await _render(
          tester,
          s,
          size: size,
          dpr: dpr,
          viewStart: start,
          days: days,
          full: false,
        );
        final plot = ChartLayout.of(size, days).plot;
        final top = (plot.top * dpr).ceil(),
            bottom = (plot.bottom * dpr).floor();
        final x0 = (plot.left * dpr).ceil() + 2;
        final x1 = (plot.right * dpr).floor() - 2;
        final a = full.extents(top, bottom), b = m4.extents(top, bottom);
        if (const bool.fromEnvironment('PARITY_DUMP')) {
          for (var x = 0; x < 14; x++) {
            // ignore: avoid_print
            print('col $x old ${a[x]} m4 ${b[x]}');
          }
          // ignore: avoid_print
          print('plot $plot');
        }
        int? gTopA, gTopB, gBotA, gBotB;
        var exactCols = 0, cols = 0;
        for (var x = x0; x < x1; x++) {
          final ea = a[x], eb = b[x];
          if (ea != null) {
            gTopA = gTopA == null || ea.$1 < gTopA ? ea.$1 : gTopA;
            gBotA = gBotA == null || ea.$2 > gBotA ? ea.$2 : gBotA;
          }
          if (eb != null) {
            gTopB = gTopB == null || eb.$1 < gTopB ? eb.$1 : gTopB;
            gBotB = gBotB == null || eb.$2 > gBotB ? eb.$2 : gBotB;
          }
          if (ea == null && eb == null) continue;
          cols++;
          if (ea == eb) exactCols++;
        }
        // Displacement: every line pixel of one drawing has a line pixel
        // of the other within [d] device px (both ways).
        final d = dpr.round();
        var worst = 0;
        for (final (p, q) in [(full, m4), (m4, full)]) {
          for (var y = top; y < bottom; y++) {
            for (var x = x0; x < x1; x++) {
              if (!p.line(x, y)) continue;
              var r = 0;
              search:
              for (; r <= 4 * d; r++) {
                for (var dy = -r; dy <= r; dy++) {
                  for (var dx = -r; dx <= r; dx++) {
                    if (dx.abs() != r && dy.abs() != r) continue;
                    final xx = x + dx, yy = y + dy;
                    if (xx < 0 || yy < 0 || xx >= q.w || yy >= q.h) continue;
                    if (q.line(xx, yy)) break search;
                  }
                }
              }
              if (r > worst) worst = r;
            }
          }
        }
        // ignore: avoid_print
        print(
          '$zoom ${w.toInt()}: $exactCols / $cols columns exact, '
          'worst displacement $worst device px',
        );
        expect(worst, lessThanOrEqualTo(d), reason: 'displacement');
        expect(gTopB, gTopA, reason: 'max balance row');
        expect(gBotB, gBotA, reason: 'min balance row');
      });
    }
  }
}
