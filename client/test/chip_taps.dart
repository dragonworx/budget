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
