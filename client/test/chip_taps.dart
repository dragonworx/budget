// Test helper: with stacked lanes a dot inspects one event, while the
// day's net chip speaks for the whole day. These taps find the chips.
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The net chips painted now (chart-local rects), the opening one excluded.
Future<List<Rect>> chartChips(WidgetTester tester) async {
  final rects = <Rect>[];
  final previous = debugVertexLabelRect;
  debugVertexLabelRect = (text, center, radius, rect) {
    if (!text.startsWith('Opening')) rects.add(rect);
  };
  for (final e
      in find
          .descendant(
            of: find.byType(BalanceChart),
            matching: find.byType(CustomPaint),
          )
          .evaluate()) {
    (e.renderObject as RenderCustomPaint).markNeedsPaint();
  }
  await tester.pump();
  debugVertexLabelRect = previous;
  return rects;
}

/// Taps net chips, one after another, until [shown] says the popup is the
/// one wanted (default: a day popup, i.e. it has its net footer).
Future<Offset> revealDayTip(
  WidgetTester tester,
  PointerDeviceKind kind, {
  bool Function()? shown,
}) async {
  final origin = tester.getTopLeft(find.byType(BalanceChart));
  final ok =
      shown ??
      () => find.byKey(const ValueKey('day-net')).evaluate().isNotEmpty;
  for (final r in await chartChips(tester)) {
    final p = origin + r.center;
    await tester.tapAt(p, kind: kind);
    await tester.pump();
    if (ok()) return p;
    await tester.pump(const Duration(seconds: 6));
  }
  fail('no net chip opened a day popup');
}

/// Grid-scans the chart for a tap that opens an occurrence popup,
/// skipping the add-event FAB that now sits on the plot (a scan that
/// hits it opens the editor, and then no tip is ever found). Prefer
/// this over tapping net chips when the test then scrubs a lane or
/// pinches: those gestures start on a lane dot, not a chip.
Future<Offset> revealOccurrenceTip(
  WidgetTester tester, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
  bool Function(Offset p)? ok,
}) async {
  final plot = tester.getRect(find.byType(BalanceChart));
  final tip = find.byKey(const ValueKey('occurrence-tooltip'));
  final fab = find.byKey(const ValueKey('add-event-fab'));
  final fabRect = fab.evaluate().isEmpty
      ? Rect.zero
      : tester.getRect(fab).inflate(16);
  final close = find.byKey(const ValueKey('editor-close'));

  Future<void> dismissEditorIfOpen() async {
    if (close.evaluate().isEmpty) return;
    await tester.tap(close);
    await tester.pumpAndSettle();
  }

  for (var fy = 0.02; fy < 0.98; fy += 0.03) {
    for (var fx = 0.05; fx < 0.98; fx += 0.04) {
      final p = Offset(
        plot.left + plot.width * fx,
        plot.top + plot.height * fy,
      );
      if (fabRect.contains(p)) continue;
      await tester.tapAt(p, kind: kind);
      await tester.pump();
      await dismissEditorIfOpen();
      if (tip.evaluate().isNotEmpty && (ok == null || ok(p))) {
        // Let the opening tap's pointer fully clear before the
        // caller starts a new gesture at the same spot.
        await tester.pump();
        return p;
      }
    }
  }
  fail('a tap should reveal some dot');
}
