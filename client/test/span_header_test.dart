// The span strip above the chart: edge dates, the selection card's span
// wording, no collisions down to 320px, and it rebuilds on its own.
import 'package:budget_client/features/timeline/duration_format.dart';
import 'package:budget_client/features/timeline/span_header.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ValueNotifier<VisibleView>> _pump(
  WidgetTester tester,
  double width,
  VisibleView v, {
  void Function()? onParentBuild,
}) async {
  tester.view.physicalSize = Size(width, 60);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final view = ValueNotifier(v);
  addTearDown(view.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            onParentBuild?.call();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: VisibleSpanHeader(view: view),
            );
          },
        ),
      ),
    ),
  );
  return view;
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

Rect _rect(WidgetTester tester, String key) {
  // The painted text, not the Align/Text box.
  final ro = tester.renderObject<RenderBox>(find.byKey(ValueKey(key)));
  return ro.localToGlobal(Offset.zero) & ro.size;
}

void main() {
  test('the visible days: first and last day at least partly in view', () {
    final (a, b) = visibleDayRange(DateTime(2026, 11, 1), 30);
    expect(a, DateTime(2026, 11, 1));
    expect(b, DateTime(2026, 11, 30));
    final (c, d) = visibleDayRange(DateTime(2026, 11, 1, 12), 1);
    expect(c, DateTime(2026, 11, 1));
    expect(d, DateTime(2026, 11, 2));
    final (e, f) = visibleDayRange(DateTime(2026, 11, 1), 0.2);
    expect(e, f);
  });

  for (final width in const [320.0, 390.0, 844.0, 1600.0]) {
    for (final (start, days) in [
      (DateTime(2026, 11, 1), 30.0),
      (DateTime(2026, 10, 25), 3 * 7.0),
      (DateTime(2026, 9, 28), 200.0),
      (DateTime(2026, 12, 28), 364.0),
      (DateTime(2025, 12, 31), 35 * 365.25),
    ]) {
      testWidgets('${width.toInt()}px, $days days: edge dates, the selection '
          "card's wording centred, nothing overlaps", (tester) async {
        await _pump(tester, width, (start: start, days: days));
        final (first, last) = visibleDayRange(start, days);
        // The same words the long-press selection card shows.
        expect(
          _text(tester, 'span-header-span'),
          formatSpanDuration(
            first,
            last,
            precision: durationPrecisionFor(days),
          ),
        );
        final strip = tester.getRect(find.byKey(const ValueKey('span-header')));
        expect(strip.height, spanHeaderHeight);
        final l = _rect(tester, 'span-header-start');
        final r = _rect(tester, 'span-header-end');
        final m = _rect(tester, 'span-header-span');
        expect(l.left, closeTo(strip.left, 0.5));
        expect(r.right, closeTo(strip.right, 0.5));
        expect(m.center.dx, closeTo(strip.center.dx, 0.5));
        expect(m.left, greaterThan(l.right + 4));
        expect(r.left, greaterThan(m.right + 4));
        for (final x in [l, r, m]) {
          expect(strip.contains(x.center), isTrue);
        }
        if (width >= 844) {
          // Wide enough (even in the wide test font) for the full date.
          expect(_text(tester, 'span-header-start'), contains('${first.year}'));
        }
      });
    }
  }

  testWidgets('a view change rebuilds the strip alone', (tester) async {
    var parentBuilds = 0;
    final view = await _pump(tester, 390, (
      start: DateTime(2026, 11, 1),
      days: 30,
    ), onParentBuild: () => parentBuilds++);
    final before = parentBuilds;
    for (var i = 1; i <= 5; i++) {
      view.value = (start: DateTime(2026, 11, 1 + i), days: 30);
      await tester.pump();
      expect(_text(tester, 'span-header-start'), '${1 + i} Nov 2026');
    }
    expect(parentBuilds, before);
  });

  for (final width in const [320.0, 390.0, 1600.0]) {
    testWidgets('golden ${width.toInt()}', (tester) async {
      await _pump(tester, width, (start: DateTime(2026, 9, 28), days: 200));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/span_header_${width.toInt()}.png'),
      );
    });
  }
}
