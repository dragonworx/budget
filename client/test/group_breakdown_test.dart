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
  GroupBin? opened;

  setUp(() {
    views = [];
    glyphs = [];
    exacts = [];
    opened = null;
    debugGroupGlyph = (b, c) => glyphs.add((b, c));
    debugExactMarkerAt = (n, c) => exacts.add((n, c));
    debugGroupOpened = (b) => opened = b;
  });
  tearDown(() {
    debugGroupGlyph = null;
    debugExactMarkerAt = null;
    debugGroupOpened = null;
  });

  Future<SynthStream> pump(WidgetTester tester, Size size) async {
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
              viewStart: DateTime(2101, 1, 1),
              visibleDays: 10 * 365.25,
              eventNames: s.names,
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

  for (final size in const [Size(390, 844), Size(1600, 900)]) {
    final w = size.width.toInt();
    testWidgets('$w: a tap on a group opens its exact breakdown', (
      tester,
    ) async {
      final s = await pump(tester, size);
      final (bin, at) = pick(size);
      await tester.tapAt(at + const Offset(2, -3)); // off-centre, nearest glyph
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

    testWidgets('$w: a double-tap on a group zooms to it, no sheet', (
      tester,
    ) async {
      await pump(tester, size);
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

  testWidgets('mouse hover over a group shows its card; off it, none', (
    tester,
  ) async {
    const size = Size(1600, 900);
    await pump(tester, size);
    final (_, at) = pick(size);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 1));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(at);
    await tester.pump();
    expect(find.byKey(const ValueKey('group-breakdown-card')), findsOneWidget);
    await mouse.moveTo(at + const Offset(0, -200));
    await tester.pump();
    expect(find.byKey(const ValueKey('group-breakdown-card')), findsNothing);
  });

  testWidgets('a tap on an exact marker shows it, never a group', (
    tester,
  ) async {
    const size = Size(390, 844);
    await pump(tester, size);
    final low = exacts.lastWhere((e) => e.$1 == 'Lowest');
    await tester.tapAt(low.$2);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(opened, isNull);
    expect(find.byKey(const ValueKey('exact-marker')), findsOneWidget);
    expect(find.text('Lowest'), findsWidgets);
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
