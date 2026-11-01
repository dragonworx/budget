// Pixel goldens of the timeline chart (spec 005 R1): the perf work must not
// change a single pixel. A matrix of zooms x lanes / lane-less x scenarios
// (alert crossings, a loan with its payoff, three combined streams) at a
// desktop and a phone size, plus 20-frame pans at 30 days and 35 years with
// a golden every fifth frame. Data is synthetic and seeded
// (test/support/synthetic_series.dart) and dated well after today, so the
// Today marker never shows and the goldens do not change by date.
//
// Regenerate only on purpose (a visual change):
//   flutter test --update-goldens test/perf/golden_chart_test.dart
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/combined.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/synthetic_series.dart';

final _seed = DateTime(2100, 1, 1);

DateTime _add(DateTime d, num days) => DateTime(
  d.year,
  d.month,
  d.day,
).add(Duration(minutes: (days * 1440).round()));

class _Scenario {
  _Scenario({
    required this.name,
    required this.series,
    required this.seedDate,
    required this.focus,
    required this.names,
    required this.events,
    required this.order,
    this.seedBalance,
    this.lossThreshold = 0,
    this.alerts = true,
    this.loanPayoffs = const {},
    this.combined = const {},
    this.otherEvents = const {},
    this.otherOrder = const [],
    this.lineStart,
  });
  final String name;
  final BalanceSeries series;
  final DateTime seedDate;
  final DateTime focus;
  final Map<String, String> names;
  final Map<String, BudgetEvent> events;
  final List<String> order;
  final double? seedBalance;
  final double lossThreshold;
  final bool alerts;
  final Map<String, DateTime> loanPayoffs;
  final Map<String, CombinedStream> combined;
  final Map<String, BudgetEvent> otherEvents;
  final List<String> otherOrder;
  final DateTime? lineStart;
}

final _scenarios = () {
  final alert = syntheticStream(
    id: 'al',
    name: 'Alerts',
    seedDate: _seed,
    mix: perfMixes['PERF 5k']!,
    seed: 5,
  );
  final loan = syntheticLoan(seedDate: _seed);
  final combo = syntheticCombined(seedDate: _seed);
  return [
    _Scenario(
      name: 'alert',
      series: alert.series,
      seedDate: alert.seedDate,
      focus: _add(_seed, 3000),
      names: alert.names,
      events: alert.byId,
      order: alert.order,
      seedBalance: alert.seedBalance,
      lossThreshold: alert.lossThreshold,
    ),
    _Scenario(
      name: 'loan',
      series: loan.series,
      seedDate: loan.seedDate,
      focus: loan.loanPayoffs.values.single,
      names: loan.names,
      events: loan.byId,
      order: loan.order,
      seedBalance: 0,
      alerts: false,
      loanPayoffs: loan.loanPayoffs,
    ),
    _Scenario(
      name: 'combined',
      series: combo.series,
      seedDate: combo.current.seedDate,
      focus: _add(_seed, 4000),
      names: combo.names,
      events: combo.current.byId,
      order: combo.current.order,
      lossThreshold: combo.current.lossThreshold,
      combined: combo.streams,
      otherEvents: combo.otherEvents,
      otherOrder: combo.otherOrder,
      lineStart: combo.lineStart,
    ),
  ];
}();

Widget _chart(
  _Scenario s, {
  required Size size,
  required DateTime viewStart,
  required double days,
  required bool lanes,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData.dark(),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: const ValueKey('golden-chart'),
        child: SizedBox.fromSize(
          size: size,
          child: BalanceChart(
            series: s.series,
            seedDate: s.seedDate,
            seedBalance: s.seedBalance,
            lossThreshold: s.lossThreshold,
            alerts: s.alerts,
            loanPayoffs: s.loanPayoffs,
            lineStart: s.lineStart,
            combinedStreams: s.combined,
            otherEvents: lanes ? s.otherEvents : const {},
            otherLaneOrder: lanes ? s.otherOrder : const [],
            viewStart: viewStart,
            visibleDays: days,
            eventNames: s.names,
            events: lanes ? s.events : const {},
            laneOrder: lanes ? s.order : const [],
            onViewportChanged: (_, _) {},
            onCreateOnDay: (_) {},
          ),
        ),
      ),
    ),
  ),
);

const _zooms = {'90d': 90.0, '1y': 365.0, '5y': 1826.0, '35y': 12785.0};
const _sizes = [Size(1600, 900), Size(390, 844)];

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

final _finder = find.byKey(const ValueKey('golden-chart'));

void main() {
  for (final s in _scenarios) {
    for (final size in _sizes) {
      for (final lanes in [false, true]) {
        for (final MapEntry(key: zoom, value: days) in _zooms.entries) {
          final tag =
              '${s.name}_${zoom}_${lanes ? 'lanes' : 'laneless'}_'
              '${size.width.toInt()}x${size.height.toInt()}';
          testWidgets('golden $tag', (tester) async {
            _useSize(tester, size);
            await tester.pumpWidget(
              _chart(
                s,
                size: size,
                viewStart: _add(s.focus, -days / 2),
                days: days,
                lanes: lanes,
              ),
            );
            await tester.pump(const Duration(seconds: 1));
            await expectLater(_finder, matchesGoldenFile('goldens/$tag.png'));
          });
        }
      }
    }
  }

  // 20-frame pans; every fifth frame is a golden (labels' hysteresis is
  // carried frame to frame, so the whole sequence must match).
  for (final (zoom, days, step) in const [
    ('30d', 30.0, 0.25),
    ('35y', 12785.0, 9.0),
  ]) {
    for (final lanes in [false, true]) {
      final tag = 'pan_${zoom}_${lanes ? 'lanes' : 'laneless'}';
      testWidgets('golden $tag', (tester) async {
        const size = Size(1600, 900);
        _useSize(tester, size);
        final s = _scenarios.first;
        final start = _add(s.focus, -days / 2);
        Widget at(int i) => _chart(
          s,
          size: size,
          viewStart: _add(start, i * step),
          days: days,
          lanes: lanes,
        );
        await tester.pumpWidget(at(0));
        await tester.pump(const Duration(seconds: 1));
        for (var i = 1; i <= 20; i++) {
          await tester.pumpWidget(at(i));
          if (i % 5 == 0) {
            await expectLater(
              _finder,
              matchesGoldenFile('goldens/${tag}_f$i.png'),
            );
          }
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  }
}
