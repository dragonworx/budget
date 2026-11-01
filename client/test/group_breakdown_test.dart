// Spec 006 §5, §7 at coarse zoom: hit-testing group glyphs and exact
// markers, the breakdown's exact totals, Zoom in and double-tap zoom.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/clusters.dart';
import 'package:budget_client/features/timeline/group_breakdown_sheet.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/synthetic_series.dart';

final _seed = DateTime(2100, 1, 1);

int _cents(Occurrence o) =>
    (o.signedDelta * Decimal.fromInt(100)).toBigInt().toInt();

/// The bin's totals straight from the occurrences (no clusters code).
({int count, int net, int credit, int debit}) _truth(
  List<Occurrence> occ,
  GroupBin b,
) {
  var count = 0, credit = 0, debit = 0;
  for (final o in occ) {
    if (o.date.isBefore(b.start) || !o.date.isBefore(b.end)) continue;
    if (o.skipped || o.netted || o.component == 'interest' || o.derived) {
      continue;
    }
    count++;
    final c = _cents(o);
    if (c > 0) {
      credit += c;
    } else {
      debit -= c;
    }
  }
  return (count: count, net: credit - debit, credit: credit, debit: debit);
}

void main() {
  late List<(DateTime, double)> views;
  late List<(GroupBin, Offset)> glyphs;
  late List<(String, Offset)> exacts;
  late Map<int, (String, bool)> labels;
  late List<(String, Rect)> labelRects;
  GroupBin? opened;

  setUp(() {
    views = [];
    glyphs = [];
    exacts = [];
    labels = {};
    labelRects = [];
    opened = null;
    debugGroupGlyph = (b, c) => glyphs.add((b, c));
    debugExactMarkerAt = (n, c) => exacts.add((n, c));
    debugGroupOpened = (b) => opened = b;
    debugVertexLabelKey = (key, label, x, shown) =>
        labels[key] = (label, shown);
    debugVertexLabelRect = (label, c, r, rect) => labelRects.add((label, rect));
    // Called once per coarse paint, before its labels: keep the last only.
    debugExactMarkers = (_) {
      labels.clear();
      labelRects.clear();
    };
  });
  tearDown(() {
    debugGroupGlyph = null;
    debugExactMarkerAt = null;
    debugGroupOpened = null;
    debugVertexLabelKey = null;
    debugVertexLabelRect = null;
    debugExactMarkers = null;
  });

  /// Fresh hook records for the next paint only.
  void resetHooks() {
    glyphs.clear();
    exacts.clear();
    labels.clear();
    labelRects.clear();
  }

  /// [lanes]: the stream's events are passed, so the chart stacks them in
  /// lanes (the real app's path), else it is a lane-less series.
  Future<SynthStream> pump(
    WidgetTester tester,
    Size size, {
    bool lanes = false,
    int panDays = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = syntheticStream(
      seedDate: _seed,
      mix: (daily: 0, weekly: 1, fortnightly: 1, monthly: 3),
      seed: 3,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.fromSize(
            size: size,
            child: BalanceChart(
              series: s.series,
              seedDate: _seed,
              seedBalance: s.series.points.first.closingBalance.toDouble(),
              lossThreshold: s.lossThreshold,
              viewStart: DateTime(2101, 1, 1 + panDays),
              visibleDays: 10 * 365.25,
              eventNames: s.names,
              events: lanes ? s.byId : const {},
              laneOrder: lanes ? s.order : const [],
              onViewportChanged: (start, days) => views.add((start, days)),
              onCreateOnDay: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    return s;
  }

  /// A glyph in the plot's middle, well clear of every exact marker.
  (GroupBin, Offset) pick(Size size) {
    final last = {for (final g in glyphs) g.$1.key: g}.values;
    return last.firstWhere(
      (g) =>
          g.$2.dx > size.width * 0.3 &&
          g.$2.dx < size.width * 0.7 &&
          g.$1.count >= 2 &&
          exacts.every((e) => (e.$2 - g.$2).distance > 40),
    );
  }

  for (final lanes in [false, true]) {
    final tag = lanes ? 'lanes, ' : '';
    for (final size in const [Size(390, 844), Size(1600, 900)]) {
      final w = size.width.toInt();
      testWidgets('$tag$w: a tap on a group opens its exact breakdown', (
        tester,
      ) async {
        final s = await pump(tester, size, lanes: lanes);
        final (bin, at) = pick(size);
        await tester.tapAt(
          at + const Offset(2, -3),
        ); // off-centre, nearest glyph
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
        await tester.pumpAndSettle();
        expect(opened?.key, bin.key);
        expect(find.byKey(const ValueKey('group-breakdown')), findsOneWidget);
        final t = _truth(s.series.occurrences, bin);
        expect(bin.count, t.count);
        expect(bin.netCents, t.net);
        expect(
          find.text(binLabel(bin.period, bin.key)),
          findsOneWidget,
          reason: 'the period is labelled',
        );
        expect(find.text(exactMoneyText(t.net)), findsWidgets);
        expect(find.text(exactMoneyText(t.credit)), findsWidgets);
        expect(find.text(exactMoneyText(-t.debit)), findsWidgets);
        // ≥ 44 pt touch targets.
        final zoom = find.byKey(const ValueKey('group-breakdown-zoom'));
        expect(tester.getSize(zoom).height, greaterThanOrEqualTo(44));

        views.clear();
        await tester.ensureVisible(zoom);
        await tester.pumpAndSettle();
        await tester.tap(zoom);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('group-breakdown')), findsNothing);
        expect(views, isNotEmpty);
        final len = dayCoord(bin.end) - dayCoord(bin.start);
        final (start, days) = views.last;
        expect(days, closeTo(len * 3, 0.5));
        expect(
          dayCoord(start) + days / 2,
          closeTo(dayCoord(bin.start) + len / 2, 0.5),
          reason: 'the period centred',
        );
      });

      testWidgets('$tag$w: a double-tap on a group zooms to it, no sheet', (
        tester,
      ) async {
        await pump(tester, size, lanes: lanes);
        final (bin, at) = pick(size);
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(at);
        await tester.pumpAndSettle();
        expect(opened, isNull);
        expect(find.byKey(const ValueKey('group-breakdown')), findsNothing);
        final len = dayCoord(bin.end) - dayCoord(bin.start);
        expect(views.last.$2, closeTo(len * 3, 0.5));
      });
    }

    testWidgets('${tag}mouse hover over a group shows its card; off it, none', (
      tester,
    ) async {
      const size = Size(1600, 900);
      await pump(tester, size, lanes: lanes);
      final (_, at) = pick(size);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(at);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('group-breakdown-card')),
        findsOneWidget,
      );
      await mouse.moveTo(at + const Offset(0, -200));
      await tester.pump();
      expect(find.byKey(const ValueKey('group-breakdown-card')), findsNothing);
    });

    testWidgets('${tag}a tap on an exact marker shows it, never a group', (
      tester,
    ) async {
      const size = Size(390, 844);
      await pump(tester, size, lanes: lanes);
      final low = exacts.lastWhere((e) => e.$1 == 'Lowest');
      await tester.tapAt(low.$2);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(opened, isNull);
      expect(find.byKey(const ValueKey('exact-marker')), findsOneWidget);
      expect(find.text('Lowest'), findsWidgets);
    });

    testWidgets('${tag}a tap right next to a ring still opens the group', (
      tester,
    ) async {
      const size = Size(390, 844);
      await pump(tester, size, lanes: lanes);
      // A glyph with an exact marker within the 24 px touch slop, but not
      // under the finger (more than 7 px off the ring's centre).
      final g = {for (final g in glyphs) g.$1.key: g}.values.where(
        (g) =>
            exacts.any((e) {
              final d = (e.$2 - g.$2).distance;
              return d > 9 && d < 24;
            }) &&
            exacts.every((e) => (e.$2 - g.$2).distance > 9),
      );
      if (g.isEmpty) {
        markTestSkipped('no glyph beside a ring in this series');
        return;
      }
      final (bin, at) = g.first;
      await tester.tapAt(at);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(opened?.key, bin.key);
      expect(find.byKey(const ValueKey('exact-marker')), findsNothing);
    });
  }

  for (final size in const [Size(390, 844), Size(1600, 900), Size(844, 390)]) {
    final w = size.width.toInt();
    testWidgets('lanes, $w: groups, exact labels, inside the plot', (
      tester,
    ) async {
      await pump(tester, size, lanes: true);
      final plot = ChartLayout.of(size, 10 * 365.25).plot;
      final k = groupLabelBudget(plot.width);
      // Pan a little: every frame keeps the guarantees.
      for (final pan in [0, 37, 91, 400]) {
        if (pan != 0) {
          resetHooks();
          await pump(tester, size, lanes: true, panDays: pan);
        }
        expect(glyphs, isNotEmpty, reason: 'group glyphs on the lane path');
        final names = {for (final e in exacts) e.$1};
        expect(names, contains('Highest'));
        expect(names, contains('Lowest'));
        // Exact markers are never dropped for a group label.
        for (final (label, shown) in labels.values) {
          if (const {
            'Highest',
            'Lowest',
            'Below alert',
            'Back above alert',
          }.contains(label)) {
            expect(shown, isTrue, reason: '$label is labelled');
          }
        }
        final groupLabels = labels.values.where(
          (l) => l.$1.contains('item') && l.$2,
        );
        expect(groupLabels, isNotEmpty, reason: 'some group labels');
        // At most K group labels (spec 006 §6).
        expect(groupLabels.length, lessThanOrEqualTo(k));
        // Never clipped: every label box inside the plot.
        for (final (label, r) in labelRects) {
          expect(
            r.left >= plot.left &&
                r.right <= plot.right &&
                r.top >= plot.top &&
                r.bottom <= plot.bottom,
            isTrue,
            reason: '$label $r inside $plot',
          );
        }
        // A group label never covers another label.
        for (var i = 0; i < labelRects.length; i++) {
          for (var j = i + 1; j < labelRects.length; j++) {
            final a = labelRects[i], b = labelRects[j];
            if (!a.$1.contains('item') && !b.$1.contains('item')) continue;
            expect(a.$2.overlaps(b.$2), isFalse, reason: '${a.$1} / ${b.$1}');
          }
        }
        // Alert crossings: a run keeps its first breach and recovery.
        final alerts = exacts.where((e) => e.$1.contains('alert')).length;
        expect(alerts, lessThanOrEqualTo(2 * (k + 2)));
      }
    });
  }

  testWidgets('lanes: a tap on a group label opens that group', (tester) async {
    const size = Size(1600, 900);
    await pump(tester, size, lanes: true);
    final (_, rect) = labelRects.firstWhere((l) => l.$1.contains('item'));
    await tester.tapAt(rect.center);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(find.byKey(const ValueKey('group-breakdown')), findsOneWidget);
  });

  test('alert runs keep only their first breach and first recovery', () {
    // Below / above every other day for 40 days, a quiet year, then again.
    final pts = <BalancePoint>[];
    var d = DateTime(2100, 1, 1);
    void add(int v) {
      pts.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(v)));
      d = DateTime(d.year, d.month, d.day + 1);
    }

    for (var i = 0; i < 40; i++) {
      add(i.isEven ? -5 : 5);
    }
    d = DateTime(d.year, d.month, d.day + 365);
    for (var i = 0; i < 6; i++) {
      add(i.isEven ? -5 : 5);
    }
    final ix = PointIndex(pts);
    bool low(double v) => v < 0;
    expect(ix.alertCrossings(0, low).length, 46);
    final kept = ix.alertRunMarks(0, low, 64);
    expect([for (final c in kept) c.$2], [true, false, true, false]);
    expect(kept[2].$1, 40, reason: 'the second run starts after the gap');
    expect(ix.alertRunMarks(0, low, 512).length, 2);
  });

  test('the breakdown counts every alert crossing in its period', () {
    final s = syntheticStream(
      seedDate: _seed,
      mix: (daily: 1, weekly: 2, fortnightly: 1, monthly: 3),
      seed: 3,
    );
    final ix = pointIndexOf(s.series.points);
    bool low(double v) => v < s.lossThreshold;
    final all = ix.alertCrossings(s.lossThreshold, low);
    final c = groupClustersOf(s.series.occurrences);
    var seen = 0;
    for (final b in c.level(BinPeriod.year).bins) {
      final d = buildGroupBreakdown(
        c,
        b,
        ix,
        nameOf: (id) => id,
        alertCrossings: all,
      );
      var below = 0, above = 0;
      for (final (i, l) in all) {
        final day = ix.sorted[i].date;
        if (day.isBefore(b.start) || !day.isBefore(b.end)) continue;
        l ? below++ : above++;
      }
      expect((d.alertBelow, d.alertAbove), (below, above));
      seen += below + above;
      expect(d.period, startsWith('1 Jan – 31 Dec '));
    }
    expect(seen, greaterThan(0), reason: 'the series crosses its alert');
  });

  test('breakdown lines sum to the bin; balances from the daily series', () {
    for (var seed = 0; seed < 6; seed++) {
      final s = syntheticStream(
        seedDate: _seed,
        mix: (daily: 1, weekly: 2, fortnightly: 1, monthly: 3),
        seed: seed,
      );
      final c = groupClustersOf(s.series.occurrences);
      final ix = pointIndexOf(s.series.points);
      for (final p in [BinPeriod.month, BinPeriod.quarter, BinPeriod.year]) {
        for (final b in c.level(p).bins.take(12)) {
          final d = buildGroupBreakdown(c, b, ix, nameOf: (id) => id);
          expect(d.lines.fold(0, (a, l) => a + l.count), b.count);
          expect(d.lines.fold(0, (a, l) => a + l.cents), b.netCents);
          final inBin = [
            for (final pt in s.series.points)
              if (!pt.date.isBefore(b.start) && pt.date.isBefore(b.end))
                pt.closingBalance.toDouble(),
          ];
          if (inBin.isEmpty) continue;
          expect(d.closing, inBin.last);
          expect(d.min, inBin.reduce((a, v) => a < v ? a : v));
          expect(d.max, inBin.reduce((a, v) => a > v ? a : v));
        }
      }
    }
  });
}
