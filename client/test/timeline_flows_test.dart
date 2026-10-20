import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime.now();
final _day = DateTime(_today.year, _today.month, _today.day);

Pool _pool({Role role = Role.owner}) => Pool(
  id: 'acc',
  ownerId: 'u',
  name: 'Everyday',
  seedBalance: Decimal.fromInt(1000),
  seedDate: _day.subtract(const Duration(days: 30)),
  lossThreshold: Decimal.zero,
  currencyScale: 1000,
  role: role,
);

Transaction _tx(String id, String name, {TransactionDirection? dir}) =>
    Transaction(
      id: id,
      poolId: 'acc',
      name: name,
      direction: dir ?? TransactionDirection.debit,
      amount: Decimal.fromInt(id == 'salary' ? 4200 : 50),
      startDate: _day.subtract(const Duration(days: 14)),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
    );

/// In-memory server: transactions, skips and a flat balance.
class _Store {
  final txs = <String, Transaction>{
    'rent': _tx('rent', 'Rent'),
    'salary': _tx('salary', 'Salary', dir: TransactionDirection.credit),
  };
  final skips = <String, Set<DateTime>>{};
  final calls = <String>[];
  Role role = Role.owner;
}

class _PoolRepo extends PoolRepository {
  _PoolRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<Pool> get(String id) async => _pool(role: s.role);

  @override
  Future<BalanceSeries> balance(
    String poolId, {
    required DateTime from,
    required DateTime to,
  }) async {
    s.calls.add('balance');
    final points = <BalancePoint>[];
    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      points.add(BalancePoint(date: d, closingBalance: Decimal.fromInt(1000)));
    }
    final occ = <Occurrence>[];
    for (final t in s.txs.values) {
      for (final d in estimateOccurrenceDates(t, maxCount: 400, through: to)) {
        if (d.isBefore(from)) continue;
        final sign = t.direction == TransactionDirection.credit ? 1 : -1;
        occ.add(
          Occurrence(
            transactionId: t.id,
            date: d,
            signedDelta: t.amount * Decimal.fromInt(sign),
            skipped: s.skips[t.id]?.contains(d) ?? false,
          ),
        );
      }
    }
    return BalanceSeries(points: points, occurrences: occ);
  }
}

class _TxRepo extends TransactionRepository {
  _TxRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<List<Transaction>> listForPool(String poolId) async =>
      s.txs.values.toList();

  @override
  Future<Transaction> update(Transaction t, {bool force = false}) async {
    s.calls.add('update ${t.id} ${t.interval} ${t.unit?.name}');
    return s.txs[t.id] = t;
  }

  @override
  Future<Transaction> create(String poolId, Transaction draft) async {
    s.calls.add('create ${draft.name}');
    return s.txs[draft.id] = draft;
  }

  @override
  Future<void> delete(String id) async {
    s.calls.add('delete $id');
    s.txs.remove(id);
  }

  @override
  Future<void> skipOccurrence(
    String transactionId,
    DateTime date, {
    bool skipped = true,
  }) async {
    s.calls.add('skip $transactionId $skipped');
    final set = s.skips.putIfAbsent(transactionId, () => {});
    skipped ? set.add(date) : set.remove(date);
  }
}

Future<_Store> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  void Function(_Store store)? setup,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // The test font (Ahem) is much wider than the app's fonts.
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = _Store();
  setup?.call(store);
  // A fresh scope per pump (a reused one would keep the last store's data).
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        poolRepositoryProvider.overrideWithValue(_PoolRepo(store)),
        transactionRepositoryProvider.overrideWithValue(_TxRepo(store)),
      ],
      child: const MaterialApp(home: TimelinePage(poolId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Taps (touch or mouse click) across the plot until a dot popup shows;
/// returns where.
Future<Offset> _revealTip(WidgetTester tester, PointerDeviceKind kind) async {
  final plot = tester.getRect(find.byType(BalanceChart));
  final tip = find.byKey(const ValueKey('occurrence-tooltip'));
  for (var fy = 0.1; fy < 0.8; fy += 0.03) {
    for (var fx = 0.3; fx < 0.98; fx += 0.04) {
      final p = Offset(
        plot.left + plot.width * fx,
        plot.top + plot.height * fy,
      );
      await tester.tapAt(p, kind: kind);
      await tester.pump();
      if (tip.evaluate().isNotEmpty) return p;
    }
  }
  fail('a tap should reveal some dot');
}

/// Salary a day after Rent, so every dot holds one transaction.
void _singles(_Store s) {
  final t = s.txs['salary']!;
  s.txs['salary'] = t.copyWith(
    startDate: t.startDate.add(const Duration(days: 1)),
  );
}

/// Opens [name]'s series in the editor through the Transactions panel
/// (the only edit path: taps on the chart just show info).
Future<void> _editFromPanel(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('open-transactions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Trim release asks first, then ends the series on that day', (
    tester,
  ) async {
    final store = await _pump(tester);
    final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart.onTrimOnDay, isNotNull, reason: 'editors can trim');
    final day = _day.add(const Duration(days: 10));
    // Cancel: nothing saved.
    chart.onTrimOnDay!(store.txs['rent']!, day, 3);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trim-dialog')), findsOneWidget);
    expect(find.textContaining('Currently repeats forever'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.calls.where((c) => c.startsWith('update')), isEmpty);
    // Confirm: saved through the normal update with the until-date end.
    chart.onTrimOnDay!(store.txs['rent']!, day, 3);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trim-confirm')));
    await tester.pumpAndSettle();
    final rent = store.txs['rent']!;
    expect(rent.endMode, EndMode.untilDate);
    expect(rent.endDate, day);
    expect(store.txs['salary']!.endMode, EndMode.never);
    expect(find.textContaining('now ends'), findsOneWidget);
  });

  testWidgets('footer tap pins a line; only its "+" opens the add flow', (
    tester,
  ) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size);
      final chart = tester.getRect(find.byType(BalanceChart));
      final footer = Offset(chart.center.dx, chart.bottom - 8);
      await tester.tapAt(footer, kind: kind);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
      // Drag along the footer and release: still only the line.
      final g = await tester.startGesture(footer, kind: kind);
      for (var i = 1; i <= 5; i++) {
        await g.moveTo(footer + Offset(i * 10.0, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-add')), kind: kind);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
    }
  });

  testWidgets('selection + opens the add editor bounded to the period; '
      'nothing saved until Save; viewers get no +', (tester) async {
    final store = await _pump(tester);
    final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart.onAddForPeriod, isNotNull);
    final start = _day.add(const Duration(days: 3));
    final end = _day.add(const Duration(days: 40));
    chart.onAddForPeriod!(start, end);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
    expect(find.text('New transaction'), findsWidgets);
    String fmt(DateTime d) => DateFormat('EEE d MMM y').format(d);
    expect(find.text(fmt(start)), findsWidgets, reason: 'start pre-filled');
    expect(find.text(fmt(end)), findsWidgets, reason: 'end pre-filled');
    final ends = tester.widget<SegmentedButton<EndMode>>(
      find.byType(SegmentedButton<EndMode>),
    );
    expect(ends.selected, {EndMode.untilDate});
    expect(store.calls.where((c) => c.startsWith('create')), isEmpty);

    await _pump(tester, setup: (s) => s.role = Role.viewer);
    expect(
      tester.widget<BalanceChart>(find.byType(BalanceChart)).onAddForPeriod,
      isNull,
    );
  });

  testWidgets('mouse hover near a dot shows the info popup; away hides it', (
    tester,
  ) async {
    final store = await _pump(tester);
    final box = tester.getRect(find.byType(BalanceChart));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.topLeft + const Offset(-5, -5));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    Offset? hit;
    for (var y = box.top + 10; y < box.bottom - 10 && hit == null; y += 6) {
      for (var x = box.left + 10; x < box.right - 10; x += 12) {
        await mouse.moveTo(Offset(x, y));
        await tester.pump();
        if (tip.evaluate().isNotEmpty) {
          hit = Offset(x, y);
          break;
        }
      }
    }
    expect(hit, isNotNull, reason: 'hovering should reach a dot');
    expect(
      find.descendant(
        of: tip,
        matching: find.textContaining(
          RegExp('Rent|Salary|Opening balance'),
          findRichText: true,
        ),
      ),
      findsWidgets,
    );
    // Far from any dot (well past the 18px mouse radius): hidden.
    await mouse.moveTo(Offset(hit!.dx, box.top + 4));
    await tester.pump();
    expect(tip, findsNothing);
    // Back on the dot, then leaving the chart hides it too.
    await mouse.moveTo(hit);
    await tester.pump();
    expect(tip, findsOneWidget);
    await mouse.moveTo(box.bottomRight + const Offset(50, 50));
    await tester.pump();
    expect(tip, findsNothing);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(store.calls.where((c) => !c.startsWith('balance')), isEmpty);
    await mouse.removePointer();
  });

  testWidgets('taps on the chart never create or edit', (tester) async {
    final store = await _pump(tester);
    final chart = find.byType(BalanceChart);
    final box = tester.getRect(chart);
    for (final f in const [0.3, 0.5, 0.7]) {
      await tester.tapAt(Offset(box.left + box.width * f, box.center.dy));
      await tester.pumpAndSettle();
    }
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(find.text('Pick one to edit its series'), findsNothing);
    expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('panel row opens the editor for that series', (tester) async {
    await _pump(tester);
    await _editFromPanel(tester, 'Salary');
    final name = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
    );
    expect(name.controller!.text, 'Salary');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('editing the frequency saves and refreshes the timeline', (
    tester,
  ) async {
    final store = await _pump(tester);
    await _editFromPanel(tester, 'Rent');
    final balanceCalls = store.calls.where((c) => c == 'balance').length;
    // Rent is weekly: Every [1] week; step up to every 2 weeks.
    expect(find.text('week'), findsWidgets);
    await tester.ensureVisible(
      find.byKey(const ValueKey('editor-interval-plus')),
    );
    await tester.tap(find.byKey(const ValueKey('editor-interval-plus')));
    await tester.pumpAndSettle();
    expect(find.text('weeks'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('update rent 2 weeks'));
    expect(find.text('Saved “Rent”'), findsOneWidget);
    expect(
      store.calls.where((c) => c == 'balance').length,
      greaterThan(balanceCalls),
    );
    expect(find.byKey(const ValueKey('focus-banner')), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('delete asks to confirm, updates the count, and can be undone', (
    tester,
  ) async {
    final store = await _pump(tester);
    expect(find.text('Transactions · 2'), findsOneWidget);
    await _editFromPanel(tester, 'Rent');
    await tester.tap(find.byKey(const ValueKey('editor-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete this series?'), findsOneWidget);
    // Cancelling keeps it.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(store.calls.where((c) => c.startsWith('delete')), isEmpty);
    await tester.tap(find.byKey(const ValueKey('editor-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('delete rent'));
    expect(find.text('Deleted “Rent”'), findsOneWidget);
    expect(find.text('Transactions · 1'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    expect(find.text('Transactions · 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('unsaved edits ask before discarding', (tester) async {
    await _pump(tester);
    await _editFromPanel(tester, 'Rent');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
      'Rent (new)',
    );
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-save')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('transactions panel opens the editor in place, back returns', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salary'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-back')), findsOneWidget);
    // Only one panel route: the list is replaced, not stacked.
    expect(find.byKey(const ValueKey('transactions-search')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transactions-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transactions-search')), findsNothing);
  });

  testWidgets('new transaction button creates and the count updates', (
    tester,
  ) async {
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-new-transaction')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      ),
      'Coffee',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(TextField),
      ),
      '4.5',
    );
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Coffee'));
    expect(find.text('Created “Coffee”'), findsOneWidget);
    expect(find.text('Transactions · 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  for (final size in const [Size(360, 740), Size(375, 812), Size(412, 839)]) {
    testWidgets('phone ${size.width.toInt()}px: compact header, no overflow, '
        'panel creates', (tester) async {
      final store = await _pump(tester, size: size);
      // Layout overflows surface as test exceptions; none expected.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('new-transaction')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-back')), findsOneWidget);
      final back = tester.getSize(find.byKey(const ValueKey('timeline-back')));
      expect(back.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(find.text('Pool settings'), findsOneWidget);
      expect(find.text('Import transactions'), findsOneWidget);
      await tester.tapAt(const Offset(5, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-transactions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('panel-new-transaction')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('editor-name')),
          matching: find.byType(TextField),
        ),
        'Tea',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
          matching: find.byType(TextField),
        ),
        '3',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('editor-save')));
      await tester.tap(find.byKey(const ValueKey('editor-save')));
      await tester.pumpAndSettle();
      expect(store.calls, contains('create Tea'));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('unit dropdown, − / + and [ ] ease the view', (tester) async {
    await _pump(tester);
    BalanceChart chart() =>
        tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart().visibleDays, inInclusiveRange(28, 31)); // Month unit
    // Opens centred on today (not aligned); ▶ snaps to a month start.
    final open = chart().viewStart;
    final mid = dayCoord(open) + chart().visibleDays / 2;
    expect(mid, inInclusiveRange(dayCoord(_day), dayCoord(_day) + 1));
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(chart().viewStart, isNot(open), reason: 'mid-ease');
    await tester.pumpAndSettle();
    final start = chart().viewStart;
    expect(start.day, 1);
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(1);
    await tester.pumpAndSettle();
    expect(chart().viewStart, DateTime(start.year, start.month + 1));
    // Rapid taps accumulate from the pending target (no drift).
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(-1);
    await tester.pump(const Duration(milliseconds: 40));
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(-1);
    await tester.pump(const Duration(milliseconds: 40));
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(-1);
    await tester.pumpAndSettle();
    expect(chart().viewStart, DateTime(start.year, start.month - 2));
    double center() => dayCoord(chart().viewStart) + chart().visibleDays / 2;
    final c0 = center();
    // +/− zoom steps (keyboard; no overlay buttons) keep the centre.
    chart().onZoomStep!(-1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-ease: between the two spans, same centre date.
    expect(chart().visibleDays, inExclusiveRange(21, 31));
    expect(center(), closeTo(c0, 1e-6));
    await tester.pumpAndSettle();
    expect(chart().visibleDays, closeTo(21, 1e-9));
    expect(center(), closeTo(c0, 1e-6));
    // Rapid taps chain from the animated state and still keep the centre.
    for (var i = 0; i < 8; i++) {
      chart().onZoomStep!(1);
      await tester.pump(const Duration(milliseconds: 40));
      expect(center(), closeTo(c0, 1e-6));
    }
    await tester.pumpAndSettle();
    expect(chart().visibleDays, anyOf(365, 366));
    expect(center(), closeTo(c0, 1e-6));
    // ◀ ▶ ease to unit-snapped starts.
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(-1);
    await tester.pumpAndSettle();
    expect(chart().viewStart.month, 1);
    expect(chart().viewStart.day, 1);
  });

  testWidgets('no dot tooltip after a pinch, whichever finger lifts last', (
    tester,
  ) async {
    await _pump(tester, size: const Size(412, 839));
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.textContaining('Balance end of day');
    // Find a spot where a plain tap shows a dot's info.
    Offset? spot;
    for (var fy = 0.1; fy < 0.8 && spot == null; fy += 0.03) {
      for (var fx = 0.3; fx < 0.98 && spot == null; fx += 0.04) {
        final p = Offset(
          plot.left + plot.width * fx,
          plot.top + plot.height * fy,
        );
        await tester.tapAt(p, kind: PointerDeviceKind.touch);
        await tester.pump();
        if (tip.evaluate().isNotEmpty) spot = p;
        await tester.pump(const Duration(seconds: 6));
      }
    }
    expect(spot, isNotNull, reason: 'a tap should reveal some dot');
    for (final firstUp in [0, 1]) {
      final a = await tester.startGesture(spot!, kind: PointerDeviceKind.touch);
      final b = await tester.startGesture(
        spot + const Offset(0, 40),
        kind: PointerDeviceKind.touch,
        pointer: 7,
      );
      for (var i = 1; i <= 5; i++) {
        await b.moveTo(spot + Offset(0, 40.0 + i * 12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 800)); // past long-press
      final gestures = [a, b];
      await gestures[firstUp].up();
      await tester.pump(const Duration(milliseconds: 700));
      expect(tip, findsNothing);
      await gestures[1 - firstUp].up();
      await tester.pump();
      expect(tip, findsNothing, reason: 'release after pinch shows no tip');
      await tester.pump(const Duration(seconds: 6));
    }
  });

  testWidgets('touch info stays pinned after lift until the next tap', (
    tester,
  ) async {
    final store = await _pump(tester, size: const Size(390, 844));
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    Offset? spot;
    for (var fy = 0.1; fy < 0.8 && spot == null; fy += 0.03) {
      for (var fx = 0.3; fx < 0.98 && spot == null; fx += 0.04) {
        final p = Offset(
          plot.left + plot.width * fx,
          plot.top + plot.height * fy,
        );
        await tester.tapAt(p, kind: PointerDeviceKind.touch);
        await tester.pump();
        if (tip.evaluate().isNotEmpty) spot = p;
      }
    }
    expect(spot, isNotNull, reason: 'a tap should reveal some dot');
    // Tap tip: no timeout on touch.
    await tester.pump(const Duration(seconds: 10));
    expect(tip, findsOneWidget);
    // Tap on empty space closes it.
    final empty = Offset(plot.left + 8, plot.top + 6);
    await tester.tapAt(empty, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(tip, findsNothing);
    // Drag-scrub from the dot, lift: the tip stays on the last dot.
    final g = await tester.startGesture(spot!, kind: PointerDeviceKind.touch);
    for (var i = 1; i <= 6; i++) {
      await g.moveTo(spot + Offset(i * 4.0, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tip, findsOneWidget);
    await g.up();
    await tester.pump(const Duration(seconds: 10));
    expect(tip, findsOneWidget, reason: 'pinned after lift');
    // A pan that starts away from dots closes it.
    final pan = await tester.startGesture(empty, kind: PointerDeviceKind.touch);
    expect(tip, findsOneWidget, reason: 'still up while the press is a tap');
    for (var i = 1; i <= 6; i++) {
      await pan.moveTo(empty + Offset(i * 8.0, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pan.up();
    await tester.pump();
    expect(tip, findsNothing);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
  });

  testWidgets('active dot highlights its balance on the y axis until '
      'navigation', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    final pill = find.byKey(const ValueKey('y-highlight'));
    final line = find.byKey(const ValueKey('y-highlight-line'));
    Future<Offset> reveal() async {
      for (var fy = 0.1; fy < 0.8; fy += 0.03) {
        for (var fx = 0.3; fx < 0.98; fx += 0.04) {
          final p = Offset(
            plot.left + plot.width * fx,
            plot.top + plot.height * fy,
          );
          await tester.tapAt(p, kind: PointerDeviceKind.touch);
          await tester.pump();
          if (tip.evaluate().isNotEmpty) return p;
        }
      }
      fail('a tap should reveal some dot');
    }

    expect(pill, findsNothing);
    await reveal();
    expect(pill, findsOneWidget);
    expect(line, findsOneWidget);
    // Pill sits at the left axis, bold.
    expect(tester.getRect(pill).left, lessThan(plot.left + 60));
    final text = tester.widget<Text>(
      find.descendant(of: pill, matching: find.byType(Text)),
    );
    expect(text.data, startsWith('\$'));
    expect(text.style?.fontWeight, FontWeight.w800);
    await tester.pump(const Duration(seconds: 10));
    expect(pill, findsOneWidget, reason: 'stays while pinned');
    // ◀ ▶ shift clears it.
    await reveal();
    expect(pill, findsOneWidget);
    tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(1);
    await tester.pumpAndSettle(); // eased pan (no refit)
    expect(pill, findsNothing);
    expect(tip, findsNothing);
    await tester.pumpAndSettle();
    // A tap on empty space clears it.
    await reveal();
    await tester.tapAt(
      Offset(plot.left + 8, plot.top + 6),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(pill, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('active dot also guides down to the date lanes and lights its '
      'date', (tester) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size);
      final chart = tester.getRect(find.byType(BalanceChart));
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final pill = find.byKey(const ValueKey('x-highlight'));
      final line = find.byKey(const ValueKey('x-highlight-line'));
      final col = find.byKey(const ValueKey('x-highlight-day'));
      final yPill = find.byKey(const ValueKey('y-highlight'));
      Future<void> reveal() async {
        for (var fy = 0.1; fy < 0.8; fy += 0.03) {
          for (var fx = 0.3; fx < 0.98; fx += 0.04) {
            final p = Offset(
              chart.left + chart.width * fx,
              chart.top + chart.height * fy,
            );
            await tester.tapAt(p, kind: kind);
            await tester.pump();
            if (tip.evaluate().isNotEmpty) return;
          }
        }
        fail('a tap should reveal some dot');
      }

      expect(pill, findsNothing);
      await reveal();
      expect(pill, findsOneWidget);
      expect(line, findsOneWidget);
      expect(col, findsOneWidget);
      expect(yPill, findsOneWidget);
      // Pill sits in the date lanes (bottom of the chart), bold, and names
      // the same day as the popup.
      expect(tester.getRect(pill).bottom, greaterThan(chart.bottom - 40));
      final text = tester.widget<Text>(
        find.descendant(of: pill, matching: find.byType(Text)),
      );
      expect(text.style?.fontWeight, FontWeight.w800);
      expect(text.data, matches(RegExp(r'^\w{3} \d{1,2} \w{3}$')));
      expect(
        find.descendant(of: tip, matching: find.textContaining(text.data!)),
        findsWidgets,
      );
      // Both pills are cyan (not the mint today / accent line colours).
      for (final key in ['x-highlight', 'y-highlight']) {
        final box = tester.widget<Container>(find.byKey(ValueKey(key)));
        final deco = box.decoration! as BoxDecoration;
        expect((deco.border! as Border).top.color, guideColor, reason: key);
      }
      // The lit column is the pill's day.
      final c = tester.getRect(col);
      expect(c.center.dx, closeTo(tester.getRect(pill).center.dx, c.width + 2));
      // Navigation clears both guides together.
      tester.widget<BalanceChart>(find.byType(BalanceChart)).onShift!(1);
      await tester.pumpAndSettle();
      expect(pill, findsNothing);
      expect(yPill, findsNothing);
      // A tap on empty space clears them too.
      await reveal();
      await tester.tapAt(Offset(chart.left + 8, chart.top + 6), kind: kind);
      await tester.pump();
      expect(pill, findsNothing);
      expect(yPill, findsNothing);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('popup Edit (one transaction) opens its editor; touch and '
      'mouse', (tester) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size, setup: _singles);
      await _revealTip(tester, kind);
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final edit = find.byKey(const ValueKey('tip-edit'));
      expect(edit, findsOneWidget);
      expect(
        find.descendant(of: edit, matching: find.text('Edit')),
        findsOneWidget,
      );
      // Which transaction the popup shows.
      final name = ['Rent', 'Salary'].firstWhere(
        (n) => find
            .descendant(of: tip, matching: find.text(n))
            .evaluate()
            .isNotEmpty,
      );
      // A tap on the card itself (not Edit) does nothing and keeps it up.
      final card = tester.getRect(tip);
      await tester.tapAt(card.topLeft + const Offset(20, 12), kind: kind);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip, findsOneWidget);
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      await tester.tap(edit, kind: kind);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-name')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, name);
      expect(tip, findsNothing);
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
      );
    }
  });

  testWidgets('mouse: moving from the dot onto Edit keeps the hover popup', (
    tester,
  ) async {
    await _pump(tester, setup: _singles);
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: plot.topLeft);
    Offset? dot;
    for (var fy = 0.1; fy < 0.8 && dot == null; fy += 0.02) {
      for (var fx = 0.3; fx < 0.98 && dot == null; fx += 0.02) {
        final p = Offset(
          plot.left + plot.width * fx,
          plot.top + plot.height * fy,
        );
        await mouse.moveTo(p);
        await tester.pump();
        if (tip.evaluate().isNotEmpty) dot = p;
      }
    }
    expect(dot, isNotNull);
    final target = tester.getCenter(find.byKey(const ValueKey('tip-edit')));
    for (var i = 1; i <= 10; i++) {
      await mouse.moveTo(Offset.lerp(dot, target, i / 10)!);
      await tester.pump();
      expect(tip, findsOneWidget, reason: 'step $i');
    }
    await tester.pump(const Duration(seconds: 8));
    expect(tip, findsOneWidget, reason: 'stays while on the card');
    await mouse.down(target);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('popup Edit (several) lists them in creation order with name '
      'and amount; the pick opens that series', (tester) async {
    for (final (size, kind, salaryFirst) in [
      (const Size(390, 844), PointerDeviceKind.touch, false),
      (const Size(1440, 900), PointerDeviceKind.mouse, true),
    ]) {
      final store = await _pump(
        tester,
        size: size,
        setup: (s) {
          if (!salaryFirst) return;
          // Salary created first: the server lists it first.
          final rent = s.txs.remove('rent')!;
          s.txs['rent'] = rent;
        },
      );
      await _revealTip(tester, kind);
      final edit = find.byKey(const ValueKey('tip-edit'));
      expect(
        find.descendant(of: edit, matching: find.text('Edit…')),
        findsOneWidget,
      );
      await tester.tap(edit, kind: kind);
      await tester.pumpAndSettle();
      final rent = find.byKey(const ValueKey('tip-edit-item-rent'));
      final salary = find.byKey(const ValueKey('tip-edit-item-salary'));
      expect(rent, findsOneWidget);
      expect(salary, findsOneWidget);
      expect(
        find.byKey(const ValueKey('occurrence-tooltip')),
        findsOneWidget,
        reason: 'popup stays up behind its menu',
      );
      final rentY = tester.getCenter(rent).dy;
      final salaryY = tester.getCenter(salary).dy;
      expect(salaryFirst ? salaryY < rentY : rentY < salaryY, isTrue);
      expect(
        find.descendant(of: rent, matching: find.text('Rent')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rent, matching: find.textContaining('50')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: salary, matching: find.textContaining('4,200')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      await tester.tap(salary, kind: kind);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-name')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller?.text, 'Salary');
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
      );
    }
  });

  testWidgets('viewers get no Edit in the popup', (tester) async {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      await _pump(tester, setup: (s) => s.role = Role.viewer);
      await _revealTip(tester, kind);
      expect(find.byKey(const ValueKey('occurrence-tooltip')), findsOneWidget);
      expect(find.byKey(const ValueKey('tip-edit')), findsNothing);
    }
  });

  testWidgets('touch popup keeps its exact rect across pointer up', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    Offset? spot;
    for (var fy = 0.1; fy < 0.8 && spot == null; fy += 0.03) {
      for (var fx = 0.3; fx < 0.98 && spot == null; fx += 0.04) {
        final p = Offset(
          plot.left + plot.width * fx,
          plot.top + plot.height * fy,
        );
        await tester.tapAt(p, kind: PointerDeviceKind.touch);
        await tester.pump();
        if (tip.evaluate().isNotEmpty) spot = p;
      }
    }
    expect(spot, isNotNull);
    final empty = Offset(plot.left + 8, plot.top + 6);
    await tester.tapAt(empty, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(tip, findsNothing);
    // Drag-scrub, then lift: same rect just before and after up.
    final g = await tester.startGesture(spot!, kind: PointerDeviceKind.touch);
    for (var i = 1; i <= 6; i++) {
      await g.moveTo(spot + Offset(i * 4.0, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final before = tester.getRect(tip);
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(tip), before, reason: 'scrub lift');
    // Tap again on the shown dot while it is pinned: still the same rect.
    // (Where the scrub started: the shown dot is the one nearest there.)
    final g2 = await tester.startGesture(spot, kind: PointerDeviceKind.touch);
    await tester.pump();
    final pressed = tester.getRect(tip);
    expect(pressed, before);
    await g2.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getRect(tip), pressed, reason: 'tap lift');
  });

  testWidgets('seed vertex shows the opening balance on tap, nothing else', (
    tester,
  ) async {
    final store = await _pump(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Seed').first);
    await tester.pumpAndSettle();
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('seed-tooltip'));
    var found = false;
    // Seed now sits at the left edge (just clear of the lane names).
    for (var fx = 0.0; fx < 0.9 && !found; fx += 0.01) {
      for (var fy = 0.05; fy < 0.85 && !found; fy += 0.04) {
        await tester.tapAt(
          Offset(
            plot.left + 40 + (plot.width - 140) * fx,
            plot.top + plot.height * fy,
          ),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump();
        found = tip.evaluate().isNotEmpty;
        if (!found) await tester.pump(const Duration(seconds: 6));
      }
    }
    expect(found, isTrue, reason: 'tapping the seed vertex shows its card');
    expect(find.text('Opening balance'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('list trash button deletes at once and Undo restores', (
    tester,
  ) async {
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-delete-rent')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('delete rent'));
    expect(find.text('Delete this series?'), findsNothing);
    expect(find.text('Deleted “Rent”'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    await tester.pump(const Duration(seconds: 3));
  });

  for (final (name, size, a11y) in const [
    ('desktop', Size(1440, 900), false),
    ('phone', Size(390, 844), false),
    ('phone, accessible navigation', Size(390, 844), true),
  ]) {
    testWidgets('$name: the Undo tip hides itself after 5s; Undo works until '
        'then', (tester) async {
      if (a11y) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(accessibleNavigation: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      final store = await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-transactions')));
      await tester.pumpAndSettle();
      Future<void> delete(String id) async {
        // Phones swipe a row left; desktop has a trash button.
        if (size.width < 600) {
          await tester.drag(
            find.byKey(ValueKey('dismiss-$id')),
            const Offset(-300, 0),
          );
          // Let the dismiss slide/resize finish until the tip shows.
          for (var i = 0; i < 20 && find.text('Undo').evaluate().isEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
        } else {
          await tester.tap(find.byKey(ValueKey('row-delete-$id')));
          await tester.pump(); // shown (entrance starts)
        }
      }

      final tip = find.byKey(const ValueKey('undo-tip'));
      await delete('rent');
      expect(tip, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 4800));
      expect(tip, findsOneWidget, reason: 'still up just before 5s');
      // Undo inside the window still restores it.
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.calls, contains('create Rent'));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // Untouched, it is gone at 5s (plus the exit animation).
      await delete('salary');
      expect(tip, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 5000));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(tip, findsNothing, reason: 'hidden after 5s');
      expect(find.text('Undo'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone: swipe left deletes; a short swipe does not', (
    tester,
  ) async {
    final store = await _pump(tester, size: const Size(360, 740));
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('dismiss-rent'));
    await tester.drag(row, const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(store.calls.where((c) => c.startsWith('delete')), isEmpty);
    await tester.drag(row, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(store.calls, contains('delete rent'));
    expect(find.text('Deleted “Rent”'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('View menu has no fit modes and no alert option (+ go-tos on '
      'phones) and starts without a divider', (tester) async {
    for (final (size, compact) in [
      (const Size(390, 844), true),
      (const Size(1440, 900), false),
    ]) {
      await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('fit-menu')));
      await tester.pumpAndSettle();
      for (final gone in ['Fit all', 'Fit vertical', 'Fit horizontal']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      // No "Keep alert line" option any more (fits never stretch to it).
      expect(find.byKey(const ValueKey('fit-threshold')), findsNothing);
      expect(find.textContaining('Keep alert line'), findsNothing);
      expect(find.byType(CheckboxMenuButton), findsNothing); // 1 pool only
      expect(find.text('Go to today'), compact ? findsOneWidget : findsNothing);
      expect(
        find.text('Go to seed date'),
        compact ? findsOneWidget : findsNothing,
      );
      final entries = tester
          .widgetList(
            find.byWidgetPredicate(
              (w) =>
                  w is MenuItemButton ||
                  w is CheckboxMenuButton ||
                  w is Divider,
            ),
          )
          .toList();
      expect(entries.first, isNot(isA<Divider>()));
      expect(entries.last, isNot(isA<Divider>()));
      if (!compact) expect(find.text('View'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fit-menu'))); // closes
      await tester.pumpAndSettle();
      expect(find.text('No other pools'), findsNothing);
      if (!compact) {
        // The fit modes stay as keyboard shortcuts, listed in the sheet.
        await tester.tap(find.byKey(const ValueKey('shortcuts-help')));
        await tester.pumpAndSettle();
        expect(find.text('Fit balance to what is in view'), findsOneWidget);
        expect(find.text('Fit all data'), findsOneWidget);
        expect(find.text('Fit all data horizontally'), findsOneWidget);
        await tester.tap(find.text('Got it'));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('toolbar order: reminders ("schedule") sits immediately left '
      'of View; no Plan button anywhere in the toolbar', (tester) async {
    double x(String key) => tester.getCenter(find.byKey(ValueKey(key))).dx;
    Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
    for (final size in const [Size(1440, 900), Size(800, 900)]) {
      await _pump(tester, size: size);
      expect(x('open-reminders'), lessThan(x('fit-menu')));
      expect(r('fit-menu').left - r('open-reminders').right, lessThan(10));
      expect(x('fit-menu'), lessThan(x('jump-to-date')));
      // Moved down from the app bar.
      expect(
        r('open-reminders').top,
        greaterThan(tester.getRect(find.byType(AppBar)).bottom - 1),
      );
      expect(find.byKey(const ValueKey('open-plan')), findsNothing);
      // Shortcuts stay at the far right.
      expect(r('shortcuts-help').right, closeTo(size.width - 16, 1));
    }
    await _pump(tester, size: const Size(390, 844));
    expect(x('jump-to-date'), lessThan(x('open-reminders')));
    expect(x('open-reminders'), lessThan(x('fit-menu')));
    expect(r('fit-menu').left - r('open-reminders').right, lessThan(10));
    expect(find.byKey(const ValueKey('open-plan-compact')), findsNothing);
    // Reminders + View sit at the right edge, the range at the left.
    expect(r('fit-menu').right, closeTo(390 - 8, 1));
    expect(r('jump-to-date').left, closeTo(8, 1));
    expect(find.byKey(const ValueKey('open-reminders')), findsOneWidget);
  });

  test('compact date range label', () {
    expect(
      compactRangeLabel(DateTime(2026, 10, 12), DateTime(2026, 11, 9)),
      '12 Oct – 9 Nov ’26',
    );
    expect(
      compactRangeLabel(DateTime(2026, 12, 28), DateTime(2027, 1, 9)),
      '28 Dec ’26 – 9 Jan ’27',
    );
  });

  for (final (size, maxW) in const [
    // (The test font is wider than the app's: ~140px real on phones.)
    (Size(320, 640), 210.0),
    (Size(390, 844), 210.0),
    (Size(800, 900), 240.0),
    (Size(1440, 900), 240.0),
  ]) {
    testWidgets('date range control is compact and readable at '
        '${size.width.toInt()}px', (tester) async {
      await _pump(tester, size: size);
      final btn = find.byKey(const ValueKey('jump-to-date'));
      expect(tester.getSize(btn).width, lessThanOrEqualTo(maxW));
      final label = find.descendant(
        of: btn,
        matching: find.textContaining('’'),
      );
      expect(label, findsOneWidget);
      final text = tester.widget<Text>(label).data!;
      expect(text, contains(' – '));
      // Not cut off, and not shrunk to unreadable.
      final para = tester.renderObject<RenderParagraph>(
        find.descendant(of: label, matching: find.byType(RichText)),
      );
      expect(para.didExceedMaxLines, isFalse);
      final scale =
          tester.getSize(label).width / para.getMaxIntrinsicWidth(100);
      expect(scale, greaterThan(0.85));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('More menu has no "Plan a payment"', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(find.text('Pool settings'), findsOneWidget);
    expect(find.text('Plan a payment'), findsNothing);
  });

  for (final size in const [Size(1440, 900), Size(390, 844)]) {
    testWidgets('${size.width.toInt()}px: Transactions New ▾ split button: '
        'New (default) and Plan', (tester) async {
      await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-transactions')));
      await tester.pumpAndSettle();
      // Main action: New opens the editor, as before.
      await tester.tap(find.byKey(const ValueKey('panel-new-transaction')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-back')));
      await tester.pumpAndSettle();
      // The menu: New and Plan.
      final menu = find.byKey(const ValueKey('panel-new-menu'));
      final main = tester.getRect(
        find.byKey(const ValueKey('panel-new-transaction')),
      );
      expect(tester.getRect(menu).left - main.right, lessThan(4));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-option-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-option-plan')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('new-option-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-back')));
      await tester.pumpAndSettle();
      expect(find.byType(PlanPanel), findsNothing);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-option-plan')));
      await tester.pumpAndSettle();
      // The panel closes and the planner opens.
      expect(find.byKey(const ValueKey('panel-new-transaction')), findsNothing);
      expect(find.byType(PlanPanel), findsOneWidget);
      expect(
        tester.widget<PlanPanel>(find.byType(PlanPanel)).tab,
        PlanTab.payment,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in const [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('double-tap (${kind.name}) zooms time 2x about the tap and '
        'centres the balance on it, eased; never edits', (tester) async {
      final store = await _pump(tester);
      final chartFinder = find.byType(BalanceChart);
      BalanceChart chart() => tester.widget<BalanceChart>(chartFinder);
      final state = tester.state(chartFinder) as dynamic;
      BalanceExtents y() => state.debugYRange as BalanceExtents;
      final rect = tester.getRect(chartFinder);
      final w = rect.width;
      final layout = ChartLayout.of(rect.size, chart().visibleDays);
      final plot = layout.plot;
      final p =
          rect.topLeft +
          Offset(plot.left + plot.width * 0.7, plot.top + plot.height * 0.3);
      final days0 = chart().visibleDays;
      final start0 = dayCoord(chart().viewStart);
      final y0 = y();
      final atDay = start0 + 0.7 * days0;
      final atBalance = y0.max - 0.3 * (y0.max - y0.min);
      final calls0 = List.of(store.calls);

      await tester.tapAt(p, kind: kind);
      await tester.pump(const Duration(milliseconds: 120));
      await tester.tapAt(p, kind: kind);
      await tester.pump();
      // Eased: part-way after ~160ms, not a jump.
      await tester.pump(const Duration(milliseconds: 160));
      final midDays = chart().visibleDays;
      expect(midDays, lessThan(days0 - 0.5));
      expect(midDays, greaterThan(days0 / 2 + 0.5));
      await tester.pump(doubleTapZoomDuration);
      await tester.pumpAndSettle();
      expect(chart().visibleDays, closeTo(days0 / 2, 1e-6));
      final start1 = dayCoord(chart().viewStart);
      expect(start1 + chart().visibleDays / 2, closeTo(atDay, 1e-3));
      final y1 = y();
      expect(y1.max - y1.min, closeTo(y0.max - y0.min, 1e-6));
      expect((y1.min + y1.max) / 2, closeTo(atBalance, 1e-6));
      // Taps never create or edit (only balance reads for the new window).
      expect(
        store.calls.where((c) => c != 'balance'),
        calls0.where((c) => c != 'balance'),
      );
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      expect(w, greaterThan(0));

      // Two taps further apart in time are just taps (no zoom).
      await tester.tapAt(p, kind: kind);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(p, kind: kind);
      await tester.pumpAndSettle();
      expect(chart().visibleDays, closeTo(days0 / 2, 1e-6));
      await tester.pump(const Duration(seconds: 6));
    });
  }

  for (final w in const [600.0, 800.0, 1000.0, 1100.0, 1440.0]) {
    testWidgets('desktop toolbar fits at ${w.toInt()}px (no overflow; '
        'condensed controls stay reachable)', (tester) async {
      await _pump(tester, size: Size(w, 900));
      expect(tester.takeException(), isNull);
      // The header keeps the name visible next to its actions.
      final name = tester.getRect(
        find.byKey(const ValueKey('header-pool-picker')),
      );
      expect(name.width, greaterThan(60));
      // No ◀ ▶ step buttons any more ([ / ] keys still step).
      expect(find.byKey(const ValueKey('shift-left')), findsNothing);
      expect(find.byKey(const ValueKey('shift-right')), findsNothing);
      for (final k in [
        'fit-menu',
        'open-reminders',
        'jump-to-date',
        'shortcuts-help',
      ]) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.right, lessThanOrEqualTo(w), reason: k);
      }
      // Today / Seed: labelled when wide, icons in between, View menu when
      // narrow.
      if (w >= 1060) {
        expect(find.text('Today'), findsOneWidget);
      } else if (w >= 760) {
        expect(find.text('Today'), findsNothing);
        expect(find.byKey(const ValueKey('go-today')), findsOneWidget);
        expect(find.byKey(const ValueKey('go-seed')), findsOneWidget);
      } else {
        expect(find.byKey(const ValueKey('go-today')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('fit-menu')));
        await tester.pumpAndSettle();
        expect(find.text('Go to today'), findsOneWidget);
        expect(find.text('Go to seed date'), findsOneWidget);
      }
    });
  }

  // ── Step buttons removed · left-aligned jumps · header logo · More menu ──

  // The seed's calendar day (seedDate is 30×24h back, so across DST it
  // can sit at 23:00 the day before).
  final seed = _pool().seedDate;
  final seedDay = DateTime(seed.year, seed.month, seed.day);

  double xOfDay(WidgetTester tester, DateTime day) {
    final c = tester.widget<BalanceChart>(find.byType(BalanceChart));
    final w = tester.getSize(find.byType(BalanceChart)).width;
    return (dayCoord(day) - dayCoord(c.viewStart)) * w / c.visibleDays;
  }

  void expectAtLeft(WidgetTester tester, DateTime day, String why) {
    final w = tester.getSize(find.byType(BalanceChart)).width;
    // The day's left edge sits just clear of the lane names / y labels.
    expect(
      xOfDay(tester, day),
      closeTo(ChartLayout.laneNameWidth(w), 0.5),
      reason: why,
    );
  }

  for (final size in const [
    Size(320, 640),
    Size(390, 844),
    Size(800, 900),
    Size(1440, 900),
  ]) {
    testWidgets('toolbar at ${size.width.toInt()}px: no step buttons, date '
        'range kept, fits; logo left of the pool name', (tester) async {
      await _pump(tester, size: size);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shift-left')), findsNothing);
      expect(find.byKey(const ValueKey('shift-right')), findsNothing);
      final range = tester.getRect(find.byKey(const ValueKey('jump-to-date')));
      expect(range.left, greaterThanOrEqualTo(0));
      expect(range.right, lessThanOrEqualTo(size.width));
      expect(range.width, greaterThan(90));
      // Budgie icon: left side of the header, after back, before the name.
      final logo = tester.getRect(find.byKey(const ValueKey('timeline-brand')));
      final back = tester.getRect(find.byKey(const ValueKey('timeline-back')));
      final name = tester.getRect(
        find.byKey(const ValueKey('header-pool-picker')),
      );
      expect(logo.left, greaterThanOrEqualTo(back.right - 1));
      expect(logo.right, lessThanOrEqualTo(name.left));
      expect(logo.left, lessThan(size.width / 3));
      expect(logo.width, size.width < 600 ? 26 : 32);
      final bar = tester.getRect(find.byType(AppBar));
      expect(logo.center.dy, closeTo(bar.center.dy, 2));
      expect(name.width, greaterThan(40));
    });
  }

  testWidgets('desktop: Today, Seed and the date picker put the day at the '
      'left edge', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('go-seed')));
    await tester.pumpAndSettle();
    expectAtLeft(tester, seedDay, 'seed');
    await tester.tap(find.byKey(const ValueKey('go-today')));
    await tester.pumpAndSettle();
    expectAtLeft(tester, _day, 'today');
    // Date picker: opens on the first visible day; pick the 15th.
    // The range label now starts on today (the first day clear of the
    // left strip); the picker opens there.
    expect(
      find.textContaining('${DateFormat('d MMM').format(_day)} – '),
      findsWidgets,
    );
    final initial = _day;
    await tester.tap(find.byKey(const ValueKey('jump-to-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expectAtLeft(tester, DateTime(initial.year, initial.month, 15), 'picked');
    // …and the range label starts on it.
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('jump-to-date')),
        matching: find.byType(Text),
      ),
    );
    expect(
      label.data,
      startsWith(
        '${DateFormat('d MMM').format(DateTime(initial.year, initial.month, 15))} ',
      ),
    );
  });

  testWidgets('phone: View menu Go to seed / today left-align too', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    for (final (label, day) in [
      ('Go to seed date', seedDay),
      ('Go to today', _day),
    ]) {
      await tester.tap(find.byKey(const ValueKey('fit-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expectAtLeft(tester, day, label);
      final range = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('jump-to-date')),
          matching: find.byType(Text),
        ),
      );
      expect(range.data, startsWith('${DateFormat('d MMM').format(day)} '));
    }
  });

  testWidgets('More menu (below 960px): Pool settings is the first item', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    final items = find.byWidgetPredicate((w) => w is PopupMenuItem<String>);
    final first = tester.widgetList<PopupMenuItem<String>>(items).toList()
      ..sort(
        (a, b) => tester
            .getTopLeft(find.byWidget(a))
            .dy
            .compareTo(tester.getTopLeft(find.byWidget(b)).dy),
      );
    expect(first.first.value, 'settings');
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Pool settings'), lessThan(y('Share pool')));
    expect(y('Share pool'), lessThan(y('Import transactions')));
    await tester.tap(find.text('Pool settings'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });
}
