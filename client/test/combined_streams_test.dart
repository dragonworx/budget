import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/combined.dart';
import 'package:budget_client/features/timeline/day_totals.dart';
import 'package:budget_client/features/timeline/fit_ranges.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';

import 'support/fake_auth.dart';

import 'support/fake_categories.dart';

final _now = DateTime.now();
final _today = DateTime(_now.year, _now.month, _now.day);
DateTime _d(int offset) =>
    DateTime(_today.year, _today.month, _today.day + offset);
Decimal _m(num v) => Decimal.parse('$v');

BudgetStream _p(
  String id,
  String name,
  int seed,
  int seedOffset, {
  Role role = Role.owner,
}) => BudgetStream(
  id: id,
  ownerId: role == Role.owner ? 'u1' : 'other',
  name: name,
  seedBalance: _m(seed),
  seedDate: _d(seedOffset),
  lossThreshold: Decimal.zero,
  role: role,
  shared: role != Role.owner,
);

BudgetEvent _tx(
  String id,
  String stream,
  EventDirection dir,
  num amount,
  DateTime on, {
  TransferLink? transfer,
}) => BudgetEvent(
  id: id,
  streamId: stream,
  name: id,
  direction: dir,
  amount: _m(amount),
  startDate: on,
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  transfer: transfer,
);

/// Three streams: Everyday (current), Savings (mine) and Kids (shared with me
/// as viewer). Everyday sends Savings 100 in 3 days (a transfer); Kids
/// spends 20 on day 6 (Kids seeds on day 5).
class _World {
  final streams = {
    'a': _p('a', 'Everyday', 1000, -30),
    'b': _p('b', 'Savings', 500, -10),
    'c': _p('c', 'Kids', 200, 5, role: Role.viewer),
  };
  late final txs = <String, List<BudgetEvent>>{
    'a': [
      _tx(
        't-out',
        'a',
        EventDirection.debit,
        100,
        _d(3),
        transfer: const TransferLink(
          peerStreamId: 'b',
          peerStreamName: 'Savings',
        ),
      ),
    ],
    'b': [
      _tx(
        't-in',
        'b',
        EventDirection.credit,
        100,
        _d(3),
        transfer: const TransferLink(
          peerStreamId: 'a',
          peerStreamName: 'Everyday',
        ),
      ),
    ],
    'c': [_tx('pocket', 'c', EventDirection.debit, 20, _d(6))],
  };
  final balanceCalls = <String>[];

  BalanceSeries series(String id, DateTime from, DateTime to) {
    final stream = streams[id]!;
    final points = <BalancePoint>[];
    final occ = <Occurrence>[];
    var bal = stream.seedBalance;
    for (
      var d = stream.seedDate;
      !d.isAfter(to);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      for (final t in txs[id]!) {
        if (t.startDate == d) {
          final delta = t.direction == EventDirection.credit
              ? t.amount
              : -t.amount;
          bal += delta;
          if (!d.isBefore(from)) {
            occ.add(Occurrence(eventId: t.id, date: d, signedDelta: delta));
          }
        }
      }
      if (!d.isBefore(from)) {
        points.add(BalancePoint(date: d, closingBalance: bal));
      }
    }
    return BalanceSeries(points: points, occurrences: occ);
  }
}

class _StreamRepo extends StreamRepository {
  _StreamRepo(this.w) : super(ApiClient());
  final _World w;

  @override
  Future<StreamList> list() async => StreamList(w.streams.values.toList());

  @override
  Future<BudgetStream> get(String id) async => w.streams[id]!;

  @override
  Future<void> markOpened(String id) async {}

  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async {
    w.balanceCalls.add(streamId);
    return w.series(streamId, from, to);
  }
}

class _TxRepo extends EventRepository {
  _TxRepo(this.w) : super(ApiClient());
  final _World w;

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      w.txs[streamId]!;
}

Future<(_World, ProviderContainer)> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final w = _World();
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      streamRepositoryProvider.overrideWithValue(_StreamRepo(w)),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
      ),
      eventRepositoryProvider.overrideWithValue(_TxRepo(w)),
    ],
  );
  addTearDown(c.dispose);
  await c.read(authProvider.future);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: TimelinePage(streamId: 'a')),
    ),
  );
  await tester.pumpAndSettle();
  return (w, c);
}

BalanceChart _chart(WidgetTester t) =>
    t.widget<BalanceChart>(find.byType(BalanceChart));

double? _close(BalanceChart c, DateTime d) => c.series.points
    .where((p) => p.date == d)
    .firstOrNull
    ?.closingBalance
    .toDouble();

Future<void> _toggleByTap(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const ValueKey('fit-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('combine-$id')));
  await tester.pumpAndSettle();
  // Stream rows keep the menu open (several can be ticked); Esc closes it.
  expect(find.byKey(ValueKey('combine-$id')), findsOneWidget);
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  setUp(page.clearLocal);

  group('combineSeries', () {
    final w = _World();
    CombinedPart part(String id) => CombinedPart(
      streamId: id,
      seedDate: w.streams[id]!.seedDate,
      series: w.series(id, _d(-40), _d(20)),
      events: w.txs[id]!,
    );

    test(
      'sums each stream\'s closing balance; a stream adds 0 before its seed',
      () {
        final s = combineSeries(part('a'), [part('b'), part('c')]);
        double at(int o) => s.points
            .firstWhere((p) => p.date == _d(o))
            .closingBalance
            .toDouble();
        expect(at(-20), 1000); // only Everyday exists
        expect(at(-10), 1500); // Savings seeded
        expect(at(2), 1500);
        expect(at(3), 1500); // transfer nets out; Kids not seeded yet
        expect(at(5), 1700); // Kids seeded
        expect(at(6), 1680); // Kids' pocket money
        expect(combinedLineStart(part('a'), [part('b')]), _d(-30));
      },
    );

    test('transfers between included streams are netted, others are not', () {
      final both = combineSeries(part('a'), [part('b')]);
      final day = groupByDay(both.occurrences)
          .firstWhere((g) => g.day == _d(3));
      expect(day.all.map((o) => o.eventId), ['t-out', 't-in']);
      expect(day.all.every((o) => o.netted), isTrue);
      expect(day.net, 0);
      expect(day.mixed, isFalse);
      expect(day.otherStreams, {'b'});
      // Savings not included: the transfer is real money out of the view.
      final alone = combineSeries(part('a'), [part('c')]);
      final out = alone.occurrences.firstWhere((o) => o.eventId == 't-out');
      expect(out.netted, isFalse);
      expect(
        alone.occurrences.firstWhere((o) => o.eventId == 'pocket').streamId,
        'c',
      );
    });

    test('nothing to combine returns the stream\'s own series', () {
      final a = part('a');
      expect(identical(combineSeries(a, const []), a.series), isTrue);
    });
  });

  test('CombineStore remembers choices per user per stream', () {
    const store = CombineStore();
    store.save('u1', 'a', {'c', 'b'});
    expect(store.load('u1', 'a'), {'b', 'c'});
    expect(store.load('u1', 'b'), isEmpty);
    expect(store.load('u2', 'a'), isEmpty);
    page.localSet(CombineStore.key('u1', 'x'), 'not json');
    expect(store.load('u1', 'x'), isEmpty);
  });

  testWidgets('View menu (touch) combines streams; the line is the sum', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    expect(_close(_chart(tester), _today), 1000);
    expect(find.byKey(const ValueKey('combined-indicator')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('fit-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Savings'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(find.text('view only'), findsOneWidget);
    expect(find.byKey(const ValueKey('combine-a')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('combine-b')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    var chart = _chart(tester);
    expect(_close(chart, _today), 1500);
    expect(chart.combinedStreams.keys, ['b']);
    expect(chart.seedBalance, isNull);
    expect(chart.lineStart, _d(-30));
    expect(find.text('Combined: 2 streams'), findsOneWidget);

    await _toggleByTap(tester, 'c');
    chart = _chart(tester);
    expect(_close(chart, _d(6)), 1680);
    expect(chart.combinedStreams['c']!.canEdit, isFalse);
    expect(chart.combinedStreams['b']!.canEdit, isTrue);
    expect(find.text('Combined: 3 streams'), findsOneWidget);

    // Unchecking goes back to the stream alone.
    await _toggleByTap(tester, 'b');
    await _toggleByTap(tester, 'c');
    chart = _chart(tester);
    expect(_close(chart, _today), 1000);
    expect(chart.combinedStreams, isEmpty);
    expect(chart.seedBalance, 1000);
    expect(find.byKey(const ValueKey('combined-indicator')), findsNothing);
  });

  testWidgets('View menu by keyboard: arrows move, Enter / Space toggle', (
    tester,
  ) async {
    await _pump(tester);
    bool focusedOn(String key) {
      final f = FocusManager.instance.primaryFocus?.context;
      if (f == null) return false;
      return find
          .ancestor(
            of: find.byWidget(f.widget),
            matching: find.byKey(ValueKey(key)),
          )
          .evaluate()
          .isNotEmpty;
    }

    await tester.tap(find.byKey(const ValueKey('fit-menu')));
    await tester.pumpAndSettle();
    // Go to today takes focus first; seed, date… and the stream rows
    // follow it.
    expect(focusedOn('view-today'), isTrue);
    for (final k in ['view-seed', 'view-go-to-date']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusedOn(k), isTrue, reason: k);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedOn('combine-b'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('combine-c')), findsOneWidget); // open
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedOn('combine-c'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('combine-c')), findsNothing);
    expect(_chart(tester).combinedStreams.keys.toSet(), {'b', 'c'});
    expect(find.text('Combined: 3 streams'), findsOneWidget);
  });

  testWidgets('choices persist per user per current stream', (tester) async {
    await _pump(tester);
    await _toggleByTap(tester, 'c');
    expect(_chart(tester).combinedStreams.keys, ['c']);
    expect(const CombineStore().load('u1', 'a'), {'c'});
    // A fresh app (same browser storage) opens combined again.
    await _pump(tester);
    expect(_chart(tester).combinedStreams.keys, ['c']);
    expect(find.text('Combined: 2 streams'), findsOneWidget);
  });

  testWidgets(
    'day totals include checked streams; internal transfers net out',
    (tester) async {
      await _pump(tester);
      await _toggleByTap(tester, 'b');
      await _toggleByTap(tester, 'c');
      final state = tester.state(find.byType(BalanceChart)) as dynamic;
      final stats = state.pickDayStats(_d(3));
      expect(stats.gains, 0); // Savings' +100 nets with Everyday's −100
      expect(stats.losses, 0);
      expect(stats.balance, 1500);
      final kids = state.pickDayStats(_d(6));
      expect(kids.losses, 20);
      expect(kids.balance, 1680);
    },
  );

  testWidgets(
    'another stream\'s spend counts in the day totals; edits stay scoped',
    (tester) async {
      final (w, c) = await _pump(tester);
      w.txs['c']!.add(_tx('lunch', 'c', EventDirection.debit, 15, _d(8)));
      c.invalidate(eventsProvider('c'));
      c.invalidate(balanceProvider);
      await tester.pumpAndSettle();
      await _toggleByTap(tester, 'c');
      final state = tester.state(find.byType(BalanceChart)) as dynamic;
      final stats = state.pickDayStats(_d(8));
      expect(stats.losses, 15);
      expect(stats.balance, 1000 - 100 + 200 - 20 - 15);
      final chart = _chart(tester);
      // Trim / Edit only ever see the current stream's events.
      expect(chart.events.keys, ['t-out']);
      expect(chart.otherEvents.keys, ['pocket', 'lunch']);
      expect(
        chart.series.occurrences
            .firstWhere((o) => o.eventId == 'lunch')
            .streamId,
        'c',
      );
    },
  );

  testWidgets('realtime-style invalidation refreshes the combined line', (
    tester,
  ) async {
    final (w, c) = await _pump(tester);
    final state = tester.state(find.byType(BalanceChart)) as dynamic;
    final y0 = state.debugYRange as BalanceExtents;
    await _toggleByTap(tester, 'b');
    expect(_close(_chart(tester), _today), 1500);
    w.streams['b'] = _p('b', 'Savings', 800, -10);
    c.invalidate(streamProvider('b'));
    c.invalidate(balanceProvider);
    await tester.pumpAndSettle();
    expect(_close(_chart(tester), _today), 1800);
    // Neither the toggle nor the refetch of the combined stream refits.
    final y1 = state.debugYRange as BalanceExtents;
    expect((y1.min, y1.max), (y0.min, y0.max));
  });

  testWidgets('popups name the other stream; edit only with edit rights', (
    tester,
  ) async {
    final (w, c) = await _pump(tester);
    // Kids (viewer) also spends on the transfer day: one dot, three streams.
    w.streams['c'] = _p('c', 'Kids', 200, -5, role: Role.viewer);
    w.txs['c']!.add(_tx('snack', 'c', EventDirection.debit, 5, _d(3)));
    c.invalidate(streamProvider('c'));
    c.invalidate(eventsProvider('c'));
    c.invalidate(balanceProvider);
    await tester.pumpAndSettle();
    await _toggleByTap(tester, 'b');
    await _toggleByTap(tester, 'c');
    // Combining keeps the old scale (the summed line may sit off-range):
    // an explicit fit brings it into view.
    _chart(tester).onFitRequested!(FitMode.all);
    await tester.pumpAndSettle();
    // The day's net chip lists every stream's event on it.
    await revealDayTip(
      tester,
      PointerDeviceKind.touch,
      shown: () =>
          find.byKey(const ValueKey('tip-stream-c')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const ValueKey('tip-stream-b')), findsOneWidget);
    expect(find.textContaining('Kids · view only'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Savings')), findsOneWidget);
    expect(find.textContaining('nets out'), findsNWidgets(2));
    // Savings is mine: its own editor. Kids is view only: no edit.
    // Each row's ⋮: Savings' row edits in Savings; Kids (view only) has
    // only + (which always creates in the current stream).
    await tester.tap(
      find.byKey(const ValueKey('tip-menu-t-in')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tip-menu-open-other-t-in')),
      findsOneWidget,
    );
    expect(find.text('Edit in Savings'), findsOneWidget);
    expect(find.byKey(const ValueKey('tip-menu-new-t-in')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('tip-menu-snack')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tip-menu-new-snack')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tip-menu-open-other-snack')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('tip-menu-edit-snack')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // Net counts only Kids' 5 (the transfer nets out).
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('day-net')),
        matching: find.text('−\$5.00'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('combined: clicking another stream\'s event label shows '
      'that day\'s popup with the stream named', (tester) async {
    final labels = <(Offset, Rect)>[];
    final lines = <(Rect, List<String>)>[];
    debugVertexLabelRect = (n, c, r, rect) => labels.add((c, rect));
    debugVertexLabelLines = (rect, l) => lines.add((rect, l));
    addTearDown(() {
      debugVertexLabelRect = null;
      debugVertexLabelLines = null;
    });
    await _pump(tester);
    await _toggleByTap(tester, 'c');
    _chart(tester).onFitRequested!(FitMode.all);
    await tester.pumpAndSettle();
    // Kids' day 6 in the middle of the view.
    _chart(tester).onViewportChanged(_d(-8), 30);
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(BalanceChart));
    // The day totals (latest paint) sit above the ribbon, flush with their
    // day: clicking one opens its day's popup. Find the one for Kids' day.
    final dots = {for (final (c, _) in labels) c};
    final seen = <Rect>{};
    var found = false;
    for (final (rect, _) in lines.reversed.take(labels.length)) {
      if (!seen.add(rect)) continue;
      Offset? spot;
      for (var fx = 0.95; fx > 0.05 && spot == null; fx -= 0.05) {
        final p = Offset(rect.left + rect.width * fx, rect.center.dy);
        if (dots.every((d) => (d - p).distance > mouseVertexHitRadius + 1)) {
          spot = p;
        }
      }
      if (spot == null) continue;
      await tester.tapAt(origin + spot, kind: PointerDeviceKind.mouse);
      await tester.pump();
      if (find.byKey(const ValueKey('tip-stream-c')).evaluate().isNotEmpty) {
        found = true;
        expect(
          find.byKey(const ValueKey('occurrence-tooltip')),
          findsOneWidget,
        );
        break;
      }
      await tester.tapAt(
        origin + const Offset(300, 790),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(seconds: 6));
    }
    expect(found, isTrue, reason: "a day total opens Kids' day popup");
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('day nets follow the combined view: a transfer between '
      'ticked streams nets out, alone it is a loss', (tester) async {
    await _pump(tester);
    double net(DateTime day) =>
        dayNetTotals(_chart(tester).series)[dayCoord(day).round()] ?? 0;
    expect(net(_d(3)), lessThan(0), reason: 'Everyday alone');
    await _toggleByTap(tester, 'b');
    expect(net(_d(3)).abs(), lessThan(0.005), reason: 'nets out');
    // Kids' pocket money (a loss) counts once Kids is ticked.
    expect(net(_d(6)), 0);
    await _toggleByTap(tester, 'c');
    expect(net(_d(6)), lessThan(0), reason: 'Kids pocket money');
  });

  for (final (name, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone', Size(390, 844)),
  ]) {
    testWidgets('$name: ticking / unticking streams never moves the view: '
        'date window and balance min/max identical every frame', (
      tester,
    ) async {
      await _pump(tester, size: size);
      // Somewhere other than the opening view: panned 9.3 days back and
      // zoomed to 45 days.
      _chart(tester).onViewportChanged(_d(-20), 45);
      await tester.pumpAndSettle();
      final start = _chart(tester).viewStart;
      final days = _chart(tester).visibleDays;
      final state = tester.state(find.byType(BalanceChart)) as dynamic;
      BalanceExtents y() => state.debugYRange as BalanceExtents;
      final y0 = y();
      void still(String why) {
        expect(_chart(tester).viewStart, start, reason: why);
        expect(_chart(tester).visibleDays, days, reason: why);
        expect(y().min, y0.min, reason: '$why: balance min');
        expect(y().max, y0.max, reason: '$why: balance max');
      }

      final lines = <double>{};
      for (final (id, why) in [
        ('b', 'tick Savings'),
        ('c', 'tick Kids'),
        ('b', 'untick Savings'),
        ('c', 'untick Kids'),
      ]) {
        await tester.tap(find.byKey(const ValueKey('fit-menu')));
        await tester.pumpAndSettle();
        still('$why, menu open');
        await tester.tap(find.byKey(ValueKey('combine-$id')));
        // Every frame while the other streams load and the line redraws.
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          still('$why, frame $i');
        }
        await tester.pumpAndSettle();
        still(why);
        lines.add(_chart(tester).series.points.last.closingBalance.toDouble());
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        still('$why, menu closed');
      }
      // The line itself did change (combined sums), only the view didn't.
      expect(lines.length, greaterThan(1));
    });
  }
}
