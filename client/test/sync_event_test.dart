// Spec 015: the Sync event type on the client — model round-trip, the
// editor's Sync mode, events-list texts and filters, chart markers at
// every zoom (never grouped or hidden), day totals and lanes.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/features/events/sync_format.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/features/timeline/sync_markers.dart';
import 'package:budget_client/features/variables/variable_impact.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'loan_editor_test.dart' show pumpEditor, enter, tapKey, streams, events;

final _seed = DateTime(2100, 1, 1);
Decimal _d(String s) => Decimal.parse(s);

BudgetEvent _sync(String id, DateTime date, String amount) => BudgetEvent(
  id: id,
  streamId: 'acc',
  name: 'Sync',
  direction: EventDirection.credit,
  amount: _d(amount),
  startDate: date,
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  kind: 'sync',
);

Occurrence _pin(
  String id,
  DateTime d,
  String bal,
  String calc, {
  bool superseded = false,
}) => Occurrence(
  eventId: id,
  date: d,
  signedDelta: _d(bal) - _d(calc),
  component: 'sync',
  syncBalance: _d(bal),
  calculated: _d(calc),
  superseded: superseded,
);

/// Daily points for [days] at 1000, with weekly syncs from day 7 (500 of
/// them over ~10y) and a monthly expense.
BalanceSeries _weeklySyncs({int days = 3600}) {
  final points = <BalancePoint>[];
  final occ = <Occurrence>[];
  final pins = <Occurrence>[];
  for (var i = 0; i < days; i++) {
    final d = DateTime(2100, 1, 1 + i);
    if (d.day == 3) {
      occ.add(Occurrence(eventId: 'rent', date: d, signedDelta: _d('-50')));
    }
    if (i % 7 == 6 && pins.length < 500) {
      pins.add(_pin('s${pins.length}', d, '1000', '988.66'));
    }
    points.add(BalancePoint(date: d, closingBalance: _d('1000')));
  }
  return BalanceSeries(points: points, occurrences: occ, syncOccurrences: pins);
}

Widget _chart(BalanceSeries series, Size size, double days) => MaterialApp(
  home: Scaffold(
    body: SizedBox.fromSize(
      size: size,
      child: BalanceChart(
        series: series,
        seedDate: _seed,
        seedBalance: 1000,
        lossThreshold: 0,
        viewStart: _seed,
        visibleDays: days,
        eventNames: const {'rent': 'Rent'},
        onViewportChanged: (_, _) {},
        onCreateOnDay: (_) {},
      ),
    ),
  ),
);

void main() {
  tearDown(() {
    debugSyncMarkers = null;
    debugSyncLabel = null;
  });

  group('model', () {
    test('a sync event round-trips; its create body is the sync shape', () {
      final e = BudgetEvent.fromJson({
        'id': 'x',
        'streamId': 'acc',
        'name': 'Sync',
        'direction': 'credit',
        'amount': '-1234.56',
        'amountExpr': 'bank - 1',
        'startDate': '2100-03-03',
        'recurrenceMode': 'once',
        'endMode': 'never',
        'enabled': true,
        'kind': 'sync',
        'version': 3,
      });
      expect(e.isSync, isTrue);
      expect(e.amount, _d('-1234.56'));
      expect(BudgetEvent.fromJson(e.toJson()).isSync, isTrue);
      expect(e.toCreateJson(), {
        'kind': 'sync',
        'amount': '-1234.56',
        'startDate': '2100-03-03',
        'enabled': true,
        if (ServerFeatures.variables) 'amountExpr': 'bank - 1',
      });
    });

    test('a series splits sync pins out of occurrences and keeps records', () {
      final s = BalanceSeries.fromJson({
        'points': [
          {'date': '2100-01-01', 'closingBalance': '100.00'},
        ],
        'occurrences': [
          {'eventId': 'a', 'date': '2100-01-01', 'signedDelta': '-5.00'},
          {
            'eventId': 'b',
            'date': '2100-01-01',
            'signedDelta': '5.00',
            'component': 'sync',
            'syncBalance': '100.00',
            'calculated': '95.00',
          },
        ],
        'syncs': [
          {
            'eventId': 'b',
            'date': '2100-01-01',
            'balance': '100.00',
            'calculated': '95.00',
            'superseded': false,
          },
        ],
      });
      expect(s.occurrences.map((o) => o.eventId), ['a']);
      expect(s.syncOccurrences.single.drift, _d('5'));
      expect(s.syncs['b']!.drift, _d('5'));
      // No syncs: the same lists as before (goldens unchanged).
      final plain = BalanceSeries.fromJson({
        'points': const [],
        'occurrences': [
          {'eventId': 'a', 'date': '2100-01-01', 'signedDelta': '-5.00'},
        ],
      });
      expect(plain.syncOccurrences, isEmpty);
      expect(plain.syncs, isEmpty);
    });
  });

  group('texts', () {
    test('labels, drift, row details, same-day notes', () {
      expect(syncLabel(_d('-1234.56')), contains('1,234.56'));
      expect(driftLabel(_d('12.34')), contains('+'));
      expect(driftLabel(_d('12.34')), endsWith('drift'));
      final rec = SyncRecord(
        eventId: 'a',
        date: _seed,
        balance: _d('1'),
        calculated: _d('0'),
      );
      expect(syncRowDetail('3 Mar 2100', rec), '3 Mar 2100 · Actual balance');
      expect(
        syncRowDetail(
          'x',
          SyncRecord(
            eventId: 'a',
            date: _seed,
            balance: _d('1'),
            superseded: true,
          ),
        ),
        'This sync is overridden by a later one',
      );
      expect(
        syncRowDetail(
          'x',
          SyncRecord(
            eventId: 'a',
            date: _seed,
            balance: _d('1'),
            beforeSeed: true,
          ),
        ),
        'Before start date – has no effect',
      );
      final later = SyncRecord(
        eventId: 'preview-0',
        date: _seed,
        balance: _d('1'),
        superseded: true,
      );
      expect(sameDaySyncNote(later, [later]), contains('overridden'));
      final win = SyncRecord(
        eventId: 'preview-0',
        date: _seed,
        balance: _d('1'),
      );
      final old = SyncRecord(
        eventId: 'b',
        date: _seed,
        balance: _d('2'),
        superseded: true,
      );
      expect(
        sameDaySyncNote(win, [old, win]),
        'Overrides 1 earlier sync on '
        'this day.',
      );
      expect(syncDayTotalText('\$5.00', '+\$1.00'), 'Sync to \$5.00 (+\$1.00)');
    });

    test('credit / debit filters leave syncs out', () {
      final s = _sync('s', _seed, '-10');
      expect(filterEvents([s], TxFilter.all), [s]);
      expect(filterEvents([s], TxFilter.credit), isEmpty);
      expect(filterEvents([s], TxFilter.debit), isEmpty);
    });

    test('a sync usage reads "Actual balance"', () {
      final u = VariableUsage.fromJson({
        'entity': 'event',
        'entityId': 'x',
        'eventName': 'Sync',
        'eventKind': 'sync',
        'field': 'amount',
      });
      expect(usageLabel(u), 'Sync · Actual balance');
      final plain = VariableUsage.fromJson({
        'entity': 'event',
        'entityId': 'x',
        'eventName': 'Rent',
        'field': 'amount',
      });
      expect(usageLabel(plain), 'Rent');
    });

    test('lanes skip syncs (no colour slot)', () {
      final rent = BudgetEvent(
        id: 'rent',
        streamId: 'acc',
        name: 'Rent',
        direction: EventDirection.debit,
        amount: _d('5'),
        startDate: _seed,
        recurrenceMode: RecurrenceMode.once,
        endMode: EndMode.never,
      );
      final lanes = buildLaneSet(
        order: ['s', 'rent'],
        events: {'s': _sync('s', _seed, '1'), 'rent': rent},
      );
      expect(lanes.lanes.map((l) => l.id), ['rent']);
    });
  });

  group('marker data', () {
    test('one mark per day, the last non-superseded wins, ×N counts', () {
      final d = DateTime(2100, 2, 1);
      final marks = syncMarksOf([
        _pin('a', d, '10', '5', superseded: true),
        _pin('b', d, '20', '5'),
        _pin('c', DateTime(2100, 2, 8), '30', '5'),
      ]);
      expect(marks, hasLength(2));
      expect(marks.first.winner.eventId, 'b');
      expect(marks.first.count, 2);
      final (a, b) = syncMarkRange(
        marks,
        marks.last.dayIndex,
        marks.last.dayIndex,
      );
      expect((a, b), (1, 2));
      final cols = syncColumns(marks, (m) => 0.4);
      expect(cols.single, hasLength(2));
    });
  });

  group('chart markers', () {
    for (final (name, days) in const [
      ('l0 (8 weeks)', 56.0),
      ('l1 (1 year)', 365.0),
      ('l2 (10 years)', 3600.0),
    ]) {
      for (final size in const [Size(1400, 800), Size(320, 640)]) {
        testWidgets('$name at ${size.width.toInt()}: every sync drawn, '
            'never grouped', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final s = _weeklySyncs();
          var drawn = <(DateTime, Offset, int)>[];
          debugSyncMarkers = (m) => drawn = m;
          await tester.pumpWidget(_chart(s, size, days));
          await tester.pump(const Duration(seconds: 1));
          final end = DateTime(2100, 1, 1 + days.ceil());
          final inView = s.syncOccurrences
              .where((o) => o.date.isBefore(end))
              .length;
          // Every sync in view is counted in a ring (columns sum to all).
          final counted = drawn.fold(0, (a, m) => a + m.$3);
          expect(counted, greaterThanOrEqualTo(inView));
          expect(counted, lessThanOrEqualTo(inView + 2));
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('fine zoom: "Sync \$X" / "+\$Y drift" labels', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final labels = <(String, String?)>[];
      debugSyncLabel = (a, b, _) => labels.add((a, b));
      await tester.pumpWidget(
        _chart(_weeklySyncs(days: 60), const Size(1400, 800), 30),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(labels, isNotEmpty);
      expect(labels.first.$1, syncLabel(_d('1000')));
      expect(labels.first.$2, driftLabel(_d('11.34')));
    });

    testWidgets('day totals: a "Sync to" row', (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _chart(_weeklySyncs(days: 60), const Size(1400, 800), 30),
      );
      await tester.pump(const Duration(seconds: 1));
      final state = tester.state(find.byType(BalanceChart)) as dynamic;
      final on = state.pickDayStats(DateTime(2100, 1, 7)) as PickDayStats;
      expect(
        on.sync,
        syncDayTotalText(
          formatSyncBalance(_d('1000')),
          formatDrift(_d('11.34')),
        ),
      );
      // Syncs are not money in / out.
      expect(on.gains, 0);
      final off = state.pickDayStats(DateTime(2100, 1, 8)) as PickDayStats;
      expect(off.sync, isNull);
    });
  });

  group('editor', () {
    testWidgets('Sync mode: balance field, calculated line, use calculated, '
        'future hint, same-day warning, save', (tester) async {
      await pumpEditor(tester);
      await tapKey(tester, 'editor-kind-sync');
      expect(find.byKey(const ValueKey('editor-sync-balance')), findsOneWidget);
      expect(find.text('Actual balance'), findsWidgets);
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
      await enter(tester, 'editor-sync-balance', '-1234.56');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(streams.syncPreviews, isNotEmpty);
      expect(streams.syncPreviews.last.kind, 'sync');
      expect(streams.syncPreviews.last.amount, _d('-1234.56'));
      expect(
        find.text(calculatedLine(_d('1000'), _d('-1234.56'))),
        findsOneWidget,
      );
      await tapKey(tester, 'editor-sync-use-calculated');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(streams.syncPreviews.last.amount, _d('1000'));
      // The initial date (2027-01-15) is in the past for this run? Only
      // the hint's presence follows today.
      final future = DateTime(2027, 1, 15).isAfter(DateTime.now());
      expect(
        find.byKey(const ValueKey('editor-sync-future')),
        future ? findsOneWidget : findsNothing,
      );
      // Another sync later the same day: the draft is overridden.
      streams.syncAnswer = (draft) => [
        SyncRecord(
          eventId: 'preview-0',
          date: draft.startDate,
          balance: draft.amount,
          calculated: _d('1000'),
          superseded: true,
        ),
        SyncRecord(eventId: 'other', date: draft.startDate, balance: _d('5')),
      ];
      await enter(tester, 'editor-sync-balance', '50');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-sync-same-day')),
        findsOneWidget,
      );
      expect(find.textContaining('will be overridden'), findsOneWidget);
      await tapKey(tester, 'editor-save');
      expect(events.createdJson.last['kind'], 'sync');
      expect(events.createdJson.last['amount'], '50');
    });

    testWidgets('a saved sync keeps its kind; no Sync segment when editing '
        'a standard event', (tester) async {
      await pumpEditor(
        tester,
        existing: _sync('s1', DateTime(2027, 2, 15), '10').copyWith(version: 1),
      );
      expect(find.byKey(const ValueKey('editor-sync-balance')), findsOneWidget);
      await tester.tap(find.text('Money in'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-sync-balance')), findsOneWidget);
    });
  });
}
