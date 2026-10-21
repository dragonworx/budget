import 'dart:async';

import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/features/transactions/transaction_editor.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:budget_client/widgets/list_glyph.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/date_heatmap.dart';
import 'package:budget_client/features/timeline/fit_ranges.dart';
import 'package:budget_client/theme/app_theme.dart';
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

Transaction _withOverrides(
  Transaction t,
  Map<DateTime, OccurrenceOverride> overrides,
) => Transaction(
  id: t.id,
  poolId: t.poolId,
  name: t.name,
  direction: t.direction,
  amount: t.amount,
  startDate: t.startDate,
  recurrenceMode: t.recurrenceMode,
  interval: t.interval,
  unit: t.unit,
  endMode: t.endMode,
  endDate: t.endDate,
  occurrenceCount: t.occurrenceCount,
  enabled: t.enabled,
  transfer: t.transfer,
  version: t.version,
  overrides: overrides,
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
    // Like the server: overrides no longer on an occurrence are pruned.
    final end = t.endMode == EndMode.untilDate ? t.endDate : null;
    return s.txs[t.id] = _withOverrides(t, {
      for (final e in t.overrides.entries)
        if (end == null || !e.key.isAfter(end)) e.key: e.value,
    });
  }

  @override
  Future<Transaction> setOverride(
    String transactionId,
    DateTime date, {
    required TransactionDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    s.calls.add('override $transactionId');
    final t = s.txs[transactionId]!;
    return s.txs[transactionId] = _withOverrides(t, {
      ...t.overrides,
      date: OccurrenceOverride(direction: direction, amount: amount),
    });
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
  for (var fy = 0.02; fy < 0.98; fy += 0.03) {
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

/// Opens the ⋮ menu of the popup row for transaction [id].
Future<void> _openRowMenu(
  WidgetTester tester,
  String id,
  PointerDeviceKind kind,
) async {
  await tester.tap(find.byKey(ValueKey('tip-menu-$id')), kind: kind);
  await tester.pumpAndSettle();
}

Finder _keyStarts(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith(prefix),
);

/// Opens [name]'s series in the editor through the Transactions panel
/// (the only edit path: taps on the chart just show info).
Future<void> _editFromPanel(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('open-transactions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

void main() {
  popupSizeProbe();
  testWidgets('the date drag has no Trim hook; the popup\'s ⋮ keeps it', (
    tester,
  ) async {
    await _pump(tester);
    final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(chart.onTrimOccurrence, isNotNull, reason: 'editors: ⋮ Trim');
    expect(find.byKey(const ValueKey('trim-dialog')), findsNothing);
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
    expect(find.byTooltip('Transactions (2)'), findsOneWidget);
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
    expect(find.byTooltip('Transactions (1)'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    expect(find.byTooltip('Transactions (2)'), findsOneWidget);
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
    expect(find.byTooltip('Transactions (3)'), findsOneWidget);
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
    final tip = find.byKey(const ValueKey('tip-balance'));
    // Find a spot where a plain tap shows a dot's info.
    Offset? spot;
    for (var fy = 0.02; fy < 0.98 && spot == null; fy += 0.03) {
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
    for (var fy = 0.02; fy < 0.98 && spot == null; fy += 0.03) {
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
      for (var fy = 0.02; fy < 0.98; fy += 0.03) {
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
        for (var fy = 0.02; fy < 0.98; fy += 0.03) {
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
      expect(
        text.data,
        matches(
          RegExp(r'^[A-Z][a-z]+day \d{1,2}(st|nd|rd|th) [A-Z][a-z]+( \d{4})?$'),
        ),
      );
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

  testWidgets('popup ⋮ → Edit (one transaction) opens its editor; the ⋮ '
      'sits after the amount on the name line; touch and mouse', (
    tester,
  ) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size, setup: _singles);
      await _revealTip(tester, kind);
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final name = ['Rent', 'Salary'].firstWhere(
        (n) => find
            .descendant(of: tip, matching: find.text(n))
            .evaluate()
            .isNotEmpty,
      );
      final id = name.toLowerCase();
      final menu = find.byKey(ValueKey('tip-menu-$id'));
      expect(menu, findsOneWidget);
      // No action strip any more: just the ⋮.
      expect(_keyStarts('tip-edit-'), findsNothing);
      expect(_keyStarts('tip-new-'), findsNothing);
      // ⋮ right after the amount, same line as the name; 44px wide target
      // on touch, compact for a mouse; the row stays compact.
      final m = tester.getRect(menu);
      final nameRect = tester.getRect(
        find.descendant(of: tip, matching: find.text(name)),
      );
      expect(m.left, greaterThan(nameRect.right));
      expect(m.top, lessThanOrEqualTo(nameRect.center.dy));
      expect(m.bottom, greaterThanOrEqualTo(nameRect.center.dy));
      final touch = kind == PointerDeviceKind.touch;
      expect(m.width, touch ? 44 : 28);
      expect(m.height, touch ? 44 : 28);
      // A tap on the card itself (not ⋮) does nothing and keeps it up.
      final card = tester.getRect(tip);
      await tester.tapAt(card.topLeft + const Offset(20, 12), kind: kind);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip, findsOneWidget);
      // Opening the menu keeps the popup; nothing opens yet.
      await _openRowMenu(tester, id, kind);
      expect(tip, findsOneWidget, reason: 'popup stays behind its menu');
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      final items = [
        find.byKey(ValueKey('tip-menu-new-$id')),
        find.byKey(ValueKey('tip-menu-trim-$id')),
        find.byKey(ValueKey('tip-menu-edit-$id')),
      ];
      for (final f in items) {
        expect(f, findsOneWidget);
      }
      // In order: New, Trim, Edit.
      expect(
        tester.getCenter(items[0]).dy,
        lessThan(tester.getCenter(items[1]).dy),
      );
      expect(
        tester.getCenter(items[1]).dy,
        lessThan(tester.getCenter(items[2]).dy),
      );
      expect(find.text('Trim'), findsOneWidget);
      expect(find.text('Trim series here'), findsNothing);
      expect(find.textContaining('New transaction on '), findsOneWidget);
      await tester.tap(items[2], kind: kind);
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

  testWidgets('popup ⋮ menu dismissed: the popup stays, nothing happens', (
    tester,
  ) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size, setup: _singles);
      store.calls.clear();
      await _revealTip(tester, kind);
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final id = find.byKey(const ValueKey('tip-menu-rent')).evaluate().isEmpty
          ? 'salary'
          : 'rent';
      await _openRowMenu(tester, id, kind);
      // Waiting past the tap-tip timeout with the menu open keeps it.
      await tester.pump(const Duration(seconds: 8));
      expect(tip, findsOneWidget);
      await tester.tapAt(const Offset(2, 2), kind: kind); // dismiss menu
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('tip-menu-edit-$id')), findsNothing);
      expect(tip, findsOneWidget, reason: 'dismissing the menu keeps it');
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      expect(store.calls.where((c) => !c.startsWith('balance')), isEmpty);
      await tester.pump(const Duration(seconds: 8));
    }
  });

  testWidgets('mouse: moving from the dot onto ⋮ keeps the hover popup', (
    tester,
  ) async {
    await _pump(tester, setup: _singles);
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: plot.topLeft);
    Offset? dot;
    for (var fy = 0.02; fy < 0.98 && dot == null; fy += 0.02) {
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
    final target = tester.getCenter(_keyStarts('tip-menu-'));
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
    expect(tip, findsOneWidget, reason: 'menu open, popup kept');
    await tester.tap(
      _keyStarts('tip-menu-edit-'),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-name')), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('popup with several transactions: one compact line each '
      '(name, amount, ⋮); ⋮ → Edit opens that series', (tester) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
      (const Size(320, 640), PointerDeviceKind.touch),
    ]) {
      final store = await _pump(tester, size: size);
      await _revealTip(tester, kind);
      final tipF = find.byKey(const ValueKey('occurrence-tooltip'));
      final tip = tester.getRect(tipF);
      expect(tip.right, lessThanOrEqualTo(size.width));
      expect(tip.width, lessThanOrEqualTo(280));
      final rows = [
        for (final id in ['rent', 'salary'])
          tester.getRect(find.byKey(ValueKey('tip-row-$id'))),
      ];
      final rowH = kind == PointerDeviceKind.touch ? 44.0 : 28.0;
      for (final (i, r) in rows.indexed) {
        final id = ['rent', 'salary'][i];
        final menu = tester.getRect(find.byKey(ValueKey('tip-menu-$id')));
        expect(r.right, lessThanOrEqualTo(tip.right));
        // At least the touch/mouse target; at most name + one meta line.
        expect(r.height, greaterThanOrEqualTo(rowH - 0.01));
        expect(r.height, lessThanOrEqualTo(44.01));
        expect(menu.height, closeTo(rowH, 0.01));
        expect(menu.width, kind == PointerDeviceKind.touch ? 44 : 28);
        // The ⋮ is inside its row, at the end.
        expect(menu.top, greaterThanOrEqualTo(r.top - 0.5));
        expect(menu.bottom, lessThanOrEqualTo(r.bottom + 0.5));
        expect(menu.right, closeTo(r.right, 0.5));
      }
      // Stacked, no gaps or dividers between them.
      expect(rows[1].top, closeTo(rows[0].bottom, 0.5));
      // One date header for the day, not one per row.
      expect(find.byKey(const ValueKey('tip-date')), findsOneWidget);
      // The footer's end-of-day balance takes all the room the net
      // leaves (a Spacer used to halve it and ellipsise the balance).
      final netR = tester.getRect(find.byKey(const ValueKey('day-net')));
      final balR = tester.getRect(find.byKey(const ValueKey('tip-balance')));
      expect(balR.left, closeTo(netR.right + 12, 1));
      expect(balR.right, closeTo(tip.right - 11, 1.5));
      await _openRowMenu(tester, 'salary', kind);
      await tester.tap(
        find.byKey(const ValueKey('tip-menu-edit-salary')),
        kind: kind,
      );
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

  testWidgets('popup "+" opens a new transaction on that day (Name focused, '
      'keyboard primed); never creates by itself; touch and mouse', (
    tester,
  ) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(tester, size: size, setup: _singles);
      store.calls.clear();
      await _revealTip(tester, kind);
      final tipText = tester
          .widget<Text>(find.byKey(const ValueKey('tip-date')))
          .data!;
      final menu = _keyStarts('tip-menu-');
      expect(menu, findsOneWidget);
      await tester.tap(menu, kind: kind);
      await tester.pumpAndSettle();
      final plus = _keyStarts('tip-menu-new-');
      expect(plus, findsOneWidget);
      expect(
        find.descendant(
          of: plus,
          matching: find.textContaining('New transaction on '),
        ),
        findsOneWidget,
      );
      final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
      final txDay = chart.series.occurrences
          .map((o) => DateTime(o.date.year, o.date.month, o.date.day))
          .firstWhere((d) => formatSelectedDate(d) == tipText);
      final primed = page.primeSoftKeyboardCalls;
      await tester.tap(plus, kind: kind);
      await tester.pumpAndSettle();
      expect(page.primeSoftKeyboardCalls, primed + 1);
      final name = find.descendant(
        of: find.byKey(const ValueKey('editor-name')),
        matching: find.byType(TextField),
      );
      expect(name, findsOneWidget);
      expect(tester.widget<TextField>(name).controller?.text, isEmpty);
      expect(
        tester.widget<TextField>(name).focusNode?.hasFocus ?? true,
        isTrue,
      );
      // The editor's date is the dot's day.
      final editor = tester.widget<TransactionEditor>(
        find.byType(TransactionEditor),
      );
      expect(editor.initialDate, txDay);
      expect(editor.existing, isNull);
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
        reason: 'only Save creates',
      );
    }
  });

  testWidgets('viewers get no Edit in the popup', (tester) async {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      await _pump(tester, setup: (s) => s.role = Role.viewer);
      await _revealTip(tester, kind);
      expect(find.byKey(const ValueKey('occurrence-tooltip')), findsOneWidget);
      expect(_keyStarts('tip-menu-'), findsNothing, reason: 'no ⋮');
    }
  });

  testWidgets('touch popup keeps its exact rect across pointer up', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    final plot = tester.getRect(find.byType(BalanceChart));
    final tip = find.byKey(const ValueKey('occurrence-tooltip'));
    Offset? spot;
    for (var fy = 0.02; fy < 0.98 && spot == null; fy += 0.03) {
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

  // ── New transaction: Name focused (phones too); new series every 1 week ──

  bool nameFocused(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-name')),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode
      .hasFocus;

  for (final (label, size, kind, viaMenu) in const [
    ('phone touch: New', Size(390, 844), PointerDeviceKind.touch, false),
    ('phone touch: New ▾ › New', Size(390, 844), PointerDeviceKind.touch, true),
    ('desktop: New', Size(1440, 900), PointerDeviceKind.mouse, false),
    ('desktop: New ▾ › New', Size(1440, 900), PointerDeviceKind.mouse, true),
  ]) {
    testWidgets('$label focuses Name (keyboard primed in the tap) and '
        'defaults to every 1 week', (tester) async {
      final store = await _pump(tester, size: size);
      await tester.tap(
        find.byKey(const ValueKey('open-transactions')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      final primed = page.primeSoftKeyboardCalls;
      if (viaMenu) {
        await tester.tap(
          find.byKey(const ValueKey('panel-new-menu')),
          kind: kind,
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('new-option-new')),
          kind: kind,
        );
      } else {
        await tester.tap(
          find.byKey(const ValueKey('panel-new-transaction')),
          kind: kind,
        );
      }
      // Primed synchronously, inside the tap.
      expect(page.primeSoftKeyboardCalls, primed + 1);
      await tester.pump();
      await tester.pump(nameRefocusDelay);
      await tester.pumpAndSettle();
      expect(nameFocused(tester), isTrue);
      // Every 1 week by default.
      expect(find.text('week'), findsWidgets);
      expect(find.text('month'), findsNothing);
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
      final created = store.txs.values.firstWhere((t) => t.name == 'Coffee');
      expect(created.unit, RecurrenceUnit.weeks);
      expect(created.interval, 1);
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('editing an existing series does not focus Name or prime the '
      'keyboard, and keeps its saved frequency', (tester) async {
    await _pump(
      tester,
      size: const Size(390, 844),
      setup: (store) => store.txs['rent'] = store.txs['rent']!.copyWith(
        unit: RecurrenceUnit.months,
        interval: 3,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-transactions')));
    await tester.pumpAndSettle();
    final primed = page.primeSoftKeyboardCalls;
    await tester.tap(find.text('Rent'), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(nameRefocusDelay);
    await tester.pumpAndSettle();
    expect(page.primeSoftKeyboardCalls, primed);
    expect(nameFocused(tester), isFalse);
    expect(find.text('months'), findsWidgets);
    expect(find.text('week'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('other create paths (showTransactionEditor) focus Name too', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    final ctx = tester.element(find.byType(BalanceChart));
    final primed = page.primeSoftKeyboardCalls;
    unawaited(showTransactionEditor(ctx, poolId: 'p1'));
    expect(page.primeSoftKeyboardCalls, primed + 1);
    await tester.pump();
    await tester.pump(nameRefocusDelay);
    await tester.pumpAndSettle();
    expect(nameFocused(tester), isTrue);
    expect(find.text('week'), findsWidgets);
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
        // The fit modes stay as keyboard shortcuts, listed in the sheet
        // (More ▸ Gestures & shortcuts).
        await tester.tap(find.byKey(const ValueKey('timeline-more')));
        await tester.pumpAndSettle();
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

  // ── Header row: every action, More (⋮) last · heatmap date range ──

  for (final (size, wide, mid, desk, tiny) in const [
    (Size(320, 640), false, false, false, true),
    (Size(390, 844), false, false, false, false),
    (Size(800, 900), false, false, true, false),
    (Size(1000, 900), false, true, true, false),
    (Size(1440, 900), true, true, true, false),
  ]) {
    testWidgets('${size.width.toInt()}px header: every action in the top row, '
        'Reminders · Transactions (plain list) · View · More at the right '
        'end; the date heatmap alone spans the second row', (tester) async {
      final w = size.width;
      await _pump(tester, size: size);
      expect(tester.takeException(), isNull);
      final bar = tester.getRect(find.byType(AppBar));
      Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
      bool inBar(String key) => find
          .descendant(
            of: find.byType(AppBar),
            matching: find.byKey(ValueKey(key)),
          )
          .evaluate()
          .isNotEmpty;
      // More is the rightmost item of the header row.
      final more = r('timeline-more');
      expect(inBar('timeline-more'), isTrue);
      for (final e
          in find
              .descendant(
                of: find.byType(AppBar),
                matching: find.byWidgetPredicate(
                  (w) => w is ButtonStyleButton || w is IconButton,
                ),
              )
              .evaluate()) {
        final rect = tester.getRect(find.byWidget(e.widget));
        expect(rect.right, lessThanOrEqualTo(more.right + 0.5));
      }
      expect(more.right, lessThanOrEqualTo(w));
      expect(more.right, greaterThan(w - 16));
      // Right end, in order: Reminders · Transactions · View · More, at
      // every width (320 included: Transactions never hides in More).
      expect(inBar('fit-menu'), isTrue);
      expect(inBar('open-reminders'), isTrue);
      expect(r('timeline-more').left, greaterThan(r('fit-menu').right - 1));
      expect(r('timeline-more').left - r('fit-menu').right, lessThan(4));
      {
        expect(inBar('open-transactions'), isTrue);
        expect(
          r('open-transactions').left,
          greaterThan(r('open-reminders').right - 1),
        );
        expect(r('fit-menu').left - r('open-transactions').right, lessThan(4));
        expect(r('open-transactions').width, greaterThanOrEqualTo(40));
        expect(r('open-transactions').right, lessThanOrEqualTo(w));
        // The glyph is painted (not transparent) when the list is closed.
        final glyph = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byKey(const ValueKey('tx-list-glyph')),
            matching: find.byType(CustomPaint),
          ),
        );
        expect((glyph.painter! as ListGlyphPainter).color.a, greaterThan(0.5));
        expect(
          tester.getSize(find.byKey(const ValueKey('tx-list-glyph'))),
          const Size(24, 24),
        );
        // A plain list icon: no outlined / tonal / filled container.
        final tx = tester.widget<IconButton>(
          find.byKey(const ValueKey('open-transactions')),
        );
        expect(tx.style, isNull);
        // Painted (ListGlyph), not an icon-font glyph a stale font lacks.
        expect(tx.icon, isA<ListGlyph>());
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('open-transactions')),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Ink ||
                  w is DecoratedBox &&
                      w.decoration is BoxDecoration &&
                      (w.decoration as BoxDecoration).border != null,
            ),
          ),
          findsNothing,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('open-transactions')))
              .height,
          greaterThanOrEqualTo(40),
        );
        expect(find.byTooltip('Transactions (2)'), findsOneWidget);
      }
      // Everything else (Today, Seed, Share, Pool settings) sits left of
      // Reminders.
      for (final k in ['go-today', 'go-seed', 'pool-share', 'pool-settings']) {
        if (inBar(k)) {
          expect(
            r(k).right,
            lessThanOrEqualTo(r('open-reminders').left + 0.5),
            reason: k,
          );
        }
      }
      // Reminders: the prominent (filled tonal) one; labelled when wide.
      expect(find.text('Reminders'), mid ? findsOneWidget : findsNothing);
      if (mid) {
        expect(
          tester.widget(find.byKey(const ValueKey('open-reminders'))),
          isA<FilledButton>(),
        );
      }
      expect(find.text('Today'), wide ? findsOneWidget : findsNothing);
      expect(
        find.byKey(const ValueKey('go-today')),
        desk ? findsOneWidget : findsNothing,
      );
      if (desk) expect(inBar('go-seed'), isTrue);
      expect(
        find.byKey(const ValueKey('pool-settings')),
        mid ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('pool-share')),
        mid ? findsOneWidget : findsNothing,
      );
      // No balance / alert summary in the header; the name is compact.
      for (final gone in ['header-today', 'header-lowest', 'header-runway']) {
        expect(find.byKey(ValueKey(gone)), findsNothing);
      }
      expect(find.textContaining('Seed \$'), findsNothing);
      final name = r('header-pool-picker');
      expect(name.width, lessThanOrEqualTo(desk ? 260 : 150));
      expect(name.width, greaterThan(40));
      expect(find.byKey(const ValueKey('open-plan')), findsNothing);
      // Second row: the heatmap alone, the timeline's full width.
      final heat = r('jump-to-date');
      final chart = tester.getRect(find.byType(BalanceChart));
      expect(heat.top, greaterThan(bar.bottom - 1));
      expect(heat.bottom, lessThan(chart.top));
      expect(heat.left, closeTo(chart.left - 1, 1.5));
      expect(heat.right, closeTo(chart.right + 1, 1.5));
      expect(r('range-start').left, lessThan(r('range-heatmap').left));
      expect(r('range-end').right, greaterThan(r('range-heatmap').right));
      // 0.3: two-digit start days ("10 Oct") are one test-font glyph wider
      // than "9 Oct"; 0.35 failed on those days at 320px.
      expect(r('range-heatmap').width, greaterThan(w * 0.3));
      // What overflowed is in More (Pool settings first when it is there).
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(find.text('Pool settings'), mid ? findsNothing : findsOneWidget);
      expect(find.text('Share pool'), mid ? findsNothing : findsOneWidget);
      expect(find.text('Import transactions'), findsOneWidget);
      expect(find.text('Gestures & shortcuts'), findsOneWidget);
      // Transactions is never duplicated in More.
      expect(find.byKey(const ValueKey('more-transactions')), findsNothing);
      expect(find.text('Transactions (2)'), findsNothing);
      expect(find.text('Plan a payment'), findsNothing);
      if (tiny) {
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('open-transactions')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('panel-new-transaction')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  // Regression: after 1e4bdcc Transactions hid in More below 360px, which
  // is what zoomed / large-display-size phones report (e.g. 390 at 115%
  // page zoom ≈ 339). It must stay in the header at every phone width.
  for (final w in const [320.0, 339.0, 359.0, 360.0, 375.0, 412.0, 430.0]) {
    testWidgets('${w.toInt()}px phone: the Transactions list icon is in the '
        'header between Reminders and View, the name keeps room', (
      tester,
    ) async {
      await _pump(tester, size: Size(w, 800));
      expect(tester.takeException(), isNull);
      Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
      final tx = r('open-transactions');
      expect(tx.left, greaterThan(r('open-reminders').right - 1));
      expect(tx.right, lessThanOrEqualTo(r('fit-menu').left + 0.5));
      expect(tx.width, greaterThanOrEqualTo(40));
      expect(r('timeline-more').right, lessThanOrEqualTo(w));
      expect(r('header-pool-picker').width, greaterThan(40));
      expect(r('header-pool-picker').right, lessThanOrEqualTo(tx.left));
      // One sync dot: on the logo below 360, in the action row otherwise.
      expect(find.byType(RealtimeDot), findsOneWidget);
      expect(
        find.byKey(const ValueKey('brand-rt-dot')),
        w < 360 ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('open-transactions')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('panel-new-transaction')),
        findsOneWidget,
      );
    });
  }

  test('heatmap buckets: one cell per day when they fit, else summed runs', () {
    final a = DateTime(2026, 10, 1);
    final k = dayCoord(a).round();
    final nets = {k: 100.0, k + 1: -40.0, k + 29: 5.0};
    final daily = heatmapBuckets(nets, a, DateTime(2026, 10, 30), 1000);
    expect(daily.length, 30);
    expect(daily[0], 100);
    expect(daily[1], -40);
    expect(daily[29], 5);
    final b = heatmapBuckets(nets, a, DateTime(2026, 10, 30), 10);
    expect(b.length, 10);
    expect(b[0], 60); // days 1-3 summed
    expect(b[9], 5);
    // Colour: gains credit-ish, losses debit-ish, zero neutral, stronger
    // for bigger magnitudes (sqrt keeps small ones visible).
    expect(heatmapColor(0, 100), heatmapNeutral);
    final gain = heatmapColor(100, 100), loss = heatmapColor(-100, 100);
    expect(gain, AppTheme.creditColor);
    expect(loss, AppTheme.debitColor);
    final small = heatmapColor(1, 100);
    expect(small, isNot(heatmapNeutral));
    double dist(Color c, Color d) =>
        (c.r - d.r).abs() + (c.g - d.g).abs() + (c.b - d.b).abs();
    expect(
      dist(small, heatmapNeutral),
      lessThan(dist(heatmapColor(50, 100), heatmapNeutral)),
    );
  });

  test('heatmap blend: one gradient stop per cell centre; an active day '
      'keeps its colour, quiet neighbours get a fading glow', () {
    final cells = [0.0, 0.0, 0.0, 100.0, 0.0, 0.0, 0.0, 0.0, -50.0, 0.0, 30.0];
    final c = heatmapBlend(cells);
    expect(c.length, cells.length);
    double dist(Color x) =>
        (x.r - heatmapNeutral.r).abs() +
        (x.g - heatmapNeutral.g).abs() +
        (x.b - heatmapNeutral.b).abs();
    bool greenish(Color x) => x.g > x.r + 0.02;
    expect(c[3], AppTheme.creditColor, reason: 'active day exact');
    expect(c[8], heatmapColor(-50, 100));
    expect(greenish(c[2]) && greenish(c[4]), isTrue);
    expect(dist(c[4]), lessThan(dist(c[3])));
    expect(dist(c[5]), lessThan(dist(c[4])));
    expect(dist(c[5]), greaterThan(0));
    expect(c[0], heatmapNeutral, reason: '3 cells away: neutral');
    // Between a loss and a gain the glows cancel towards neutral.
    expect(dist(c[9]), lessThan(dist(c[7]) * 0.5));
    final p = HeatmapPainter(colors: c);
    expect(p.gradient!.colors, c);
    expect(p.stops.length, c.length);
    expect(p.stops.first, closeTo(0.5 / c.length, 1e-9));
    expect(p.stops.last, closeTo(1 - 0.5 / c.length, 1e-9));
    for (var i = 1; i < p.stops.length; i++) {
      expect(p.stops[i], greaterThan(p.stops[i - 1]));
    }
    expect(HeatmapPainter(colors: [heatmapNeutral]).gradient, isNull);
  });

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()}px heatmap: a cell per visible day, '
        'coloured by the day net (Rent red, Salary green), live on zoom; '
        'tap opens the date picker', (tester) async {
      await _pump(tester, size: size);
      HeatmapPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byKey(const ValueKey('range-heatmap')),
                  )
                  .painter!
              as HeatmapPainter;
      final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
      final colors = painter().colors;
      // One cell per day from the first clear day to the last visible one.
      final start = tester
          .widget<Text>(find.byKey(const ValueKey('range-start')))
          .data!;
      expect(start, isNotEmpty);
      expect(colors.length, greaterThan(10));
      expect(colors.length, lessThan(chart.visibleDays + 2));
      // Exactly the day nets of what the chart shows (footer rule), each
      // cell gain-green / loss-red / neutral by sign.
      final nets = dayNetTotals(chart.series);
      final total = nets.values.fold<double>(0, (a, b) => a + b.abs());
      expect(total, greaterThan(0));
      bool greenish(Color c) => c.g > c.r + 0.05;
      bool reddish(Color c) => c.r > c.g + 0.05;
      final gains = colors.where(greenish).length;
      expect(gains, greaterThan(0), reason: 'Salary (net +) days');
      expect(colors.where(reddish), isEmpty, reason: 'no net-loss days here');
      expect(colors.where((c) => c == heatmapNeutral), isNotEmpty);
      // One continuous gradient: a stop per day centre, not blocks.
      final g = painter().gradient!;
      expect(g.colors, colors);
      expect(g.stops, painter().stops);
      expect(g.stops!.length, colors.length);
      expect(painter().todayFraction, isNotNull, reason: 'today marker');
      // Zooming out changes the cells live.
      final n0 = colors.length;
      tester
          .widget<BalanceChart>(find.byType(BalanceChart))
          .onViewportChanged(chart.viewStart, chart.visibleDays * 3);
      await tester.pumpAndSettle();
      expect(painter().colors.length, isNot(n0));
      // Tap: the date picker, as before.
      await tester.tap(find.byKey(const ValueKey('jump-to-date')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
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
    expect(_rangeStart(tester), DateFormat('d MMM').format(_day));
    final initial = _day;
    await tester.tap(find.byKey(const ValueKey('jump-to-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expectAtLeft(tester, DateTime(initial.year, initial.month, 15), 'picked');
    // …and the range label starts on it.
    expect(
      _rangeStart(tester),
      DateFormat('d MMM').format(DateTime(initial.year, initial.month, 15)),
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
      expect(_rangeStart(tester), DateFormat('d MMM').format(day));
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

  for (final (size, label) in const [
    (Size(390, 844), 'phone'),
    (Size(1440, 900), 'desktop'),
  ]) {
    testWidgets('on open the \$0 line sits a third up the plot ($label)', (
      tester,
    ) async {
      final zeros = <(double, Rect)>[];
      debugZeroLine = (y, plot) => zeros.add((y, plot));
      addTearDown(() => debugZeroLine = null);
      await _pump(tester, size: size);
      expect(zeros, isNotEmpty);
      final (y, plot) = zeros.last;
      expect(y, closeTo(plot.top + 2 / 3 * plot.height, 0.5));
    });
  }

  testWidgets('popup Trim ends that row\'s series at the tapped occurrence; '
      'the 5s tip\'s Undo restores the end and once-offs', (tester) async {
    final far = _day.add(const Duration(days: 70));
    for (final (size, kind) in const [
      (Size(390, 844), PointerDeviceKind.touch),
      (Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      final store = await _pump(
        tester,
        size: size,
        setup: (s) => s.txs['rent'] = _withOverrides(s.txs['rent']!, {
          far: OccurrenceOverride(
            direction: TransactionDirection.debit,
            amount: Decimal.fromInt(99),
          ),
        }),
      );
      store.calls.clear();
      await _revealTip(tester, kind);
      // Rent and Salary share each dot: each row's ⋮ has its own Trim.
      await _openRowMenu(tester, 'salary', kind);
      expect(
        find.byKey(const ValueKey('tip-menu-trim-salary')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _openRowMenu(tester, 'rent', kind);
      final trimRent = find.byKey(const ValueKey('tip-menu-trim-rent'));
      expect(trimRent, findsOneWidget);
      expect(store.calls.where((c) => !c.startsWith('balance')), isEmpty);
      await tester.tap(trimRent, kind: kind);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final rent = store.txs['rent']!;
      expect(rent.endMode, EndMode.untilDate);
      final end = rent.endDate!;
      expect(
        estimateOccurrenceDates(rent, maxCount: 400).last,
        end,
        reason: 'the tapped occurrence is the last one',
      );
      expect(rent.overrides, isEmpty, reason: 'once-off past the end goes');
      expect(store.txs['salary']!.endMode, EndMode.never);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
      final tip = find.byKey(const ValueKey('undo-tip'));
      expect(tip, findsOneWidget);
      expect(
        find.descendant(of: tip, matching: find.text('Series trimmed')),
        findsOneWidget,
      );
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final back = store.txs['rent']!;
      expect(back.endMode, EndMode.never);
      expect(back.endDate, isNull);
      expect(back.overrides.keys, [far]);
      await tester.pump(const Duration(seconds: 6));
    }
  });

  testWidgets('popup Trim: none for viewers, nor on a series\' last '
      'occurrence', (tester) async {
    await _pump(tester, setup: (s) => s.role = Role.viewer);
    await _revealTip(tester, PointerDeviceKind.mouse);
    expect(_keyStarts('tip-menu'), findsNothing);
    // Every dot is Rent's last (and only) occurrence: no Trim for it.
    await _pump(
      tester,
      size: const Size(390, 844),
      setup: (s) {
        s.txs['rent'] = s.txs['rent']!.copyWith(
          endMode: EndMode.count,
          occurrenceCount: 1,
          startDate: _day,
        );
        s.txs['salary'] = s.txs['salary']!.copyWith(
          endMode: EndMode.count,
          occurrenceCount: 1,
          startDate: _day,
        );
      },
    );
    await _revealTip(tester, PointerDeviceKind.touch);
    for (final id in ['rent', 'salary']) {
      await _openRowMenu(tester, id, PointerDeviceKind.touch);
      expect(find.byKey(ValueKey('tip-menu-trim-$id')), findsNothing);
      expect(find.byKey(ValueKey('tip-menu-edit-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('tip-menu-new-$id')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  });

  test('viewForRange: picked first day clear of the strip, picked last day '
      'the last visible one', () {
    for (final w in [390.0, 1440.0]) {
      for (final (a, b) in [
        (DateTime(2026, 10, 5), DateTime(2026, 11, 4)),
        (DateTime(2026, 1, 1), DateTime(2026, 1, 1)),
        (DateTime(2026, 3, 1), DateTime(2027, 2, 28)),
      ]) {
        final (start, days) = viewForRange(
          a,
          b,
          w,
          stripWidth: ChartLayout.laneNameWidth(w),
        );
        final inset = ChartLayout.laneNameWidth(w) * days / w;
        final firstClear = dateFromDayCoord(
          (dayCoord(start) + inset - 1e-6).ceilToDouble(),
        );
        expect(firstClear, a, reason: '$w $a');
        expect(lastVisibleDay(start, days), b, reason: '$w $b');
      }
    }
  });

  for (final (size, kind) in const [
    (Size(390, 844), PointerDeviceKind.touch),
    (Size(1440, 900), PointerDeviceKind.mouse),
  ]) {
    testWidgets('${size.width.toInt()}px ${kind.name}: start / end labels '
        'edit that end of the view; past the other end the span is kept', (
      tester,
    ) async {
      final store = await _pump(tester, size: size);
      final handle = tester.ensureSemantics();
      String startText() =>
          tester.widget<Text>(find.byKey(const ValueKey('range-start'))).data!;
      String endText() =>
          tester.widget<Text>(find.byKey(const ValueKey('range-end'))).data!;
      String d(DateTime x, {bool year = false}) => year
          ? '${DateFormat('d MMM').format(x)} ’${DateFormat('yy').format(x)}'
          : DateFormat('d MMM').format(x);
      BalanceChart chart() =>
          tester.widget<BalanceChart>(find.byType(BalanceChart));
      DateTime first() => DateFormat('d MMM y').parse(
        '${startText().split(' ').take(2).join(' ')} ${_firstYear(tester)}',
      );
      DateTime last() => lastVisibleDay(chart().viewStart, chart().visibleDays);
      // Clear tap targets, three separate screen-reader buttons.
      for (final k in ['range-start-button', 'range-end-button']) {
        expect(
          tester.getSize(find.byKey(ValueKey(k))).height,
          greaterThanOrEqualTo(44),
        );
      }
      expect(
        find.bySemanticsLabel(RegExp(r'^Start date: .*Edit start date$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^End date: .*Edit end date$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Jump to a date: ')),
        findsOneWidget,
      );
      handle.dispose();

      Future<void> pick(
        String key,
        String help,
        DateTime initial,
        DateTime day,
      ) async {
        await tester.tap(find.byKey(ValueKey(key)), kind: kind);
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.text(help), findsOneWidget);
        await tester.tap(find.byTooltip('Switch to input'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byType(TextField),
        );
        expect(
          tester.widget<TextField>(field).controller!.text,
          DateFormat('MM/dd/yyyy').format(initial),
          reason: 'opens on the tapped date',
        );
        await tester.enterText(field, DateFormat('MM/dd/yyyy').format(day));
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }

      // Start earlier: the end stays, the span grows.
      final e0 = last();
      final s1 = _plus(first(), -9);
      await pick('range-start-button', 'Start date', first(), s1);
      expect(first(), s1);
      expect(last(), e0);
      // End later: the start stays.
      final e1 = _plus(e0, 12);
      await pick('range-end-button', 'End date', e0, e1);
      expect(first(), s1);
      expect(last(), e1);
      // End before the start: same span, ending on that day.
      final span = chart().visibleDays;
      final e2 = _plus(s1, -20);
      await pick('range-end-button', 'End date', e1, e2);
      expect(last(), e2);
      expect(chart().visibleDays, closeTo(span, 1e-6));
      // Start on / after the end: same span, starting on that day.
      final s3 = _plus(last(), 40);
      await pick('range-start-button', 'Start date', first(), s3);
      expect(first(), s3);
      expect(chart().visibleDays, closeTo(span, 1e-6));
      // The strip between the labels opens the start picker.
      await tester.tap(
        find.byKey(const ValueKey('range-heatmap-button')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(find.text('Start date'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(endText(), d(last(), year: true));
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
        reason: 'taps never create or edit',
      );
    });
  }

  for (final (size, kind) in const [
    (Size(390, 844), PointerDeviceKind.touch),
    (Size(1440, 900), PointerDeviceKind.mouse),
  ]) {
    testWidgets('${size.width.toInt()}px ${kind.name}: tapping a transaction '
        'label shows its dot\'s popup (same day, same place); never creates', (
      tester,
    ) async {
      final labels = <(Offset, Rect)>[];
      debugVertexLabelRect = (name, c, r, rect) => labels.add((c, rect));
      addTearDown(() => debugVertexLabelRect = null);
      final store = await _pump(tester, size: size);
      store.calls.clear();
      final origin = tester.getTopLeft(find.byType(BalanceChart));
      final plot = ChartLayout.of(
        tester.getSize(find.byType(BalanceChart)),
        tester.widget<BalanceChart>(find.byType(BalanceChart)).visibleDays,
      ).plot;
      final painted = {for (final (c, r) in labels) c: r};
      final dots = painted.keys.toList();
      final radius = vertexHitRadius(kind);
      // A point on a label beyond every dot's hit radius (so only the label
      // hit test can find it).
      Offset? spot;
      Offset? dot;
      for (final MapEntry(key: c, value: r) in painted.entries) {
        if (!plot.contains(c)) continue;
        for (var fx = 0.95; fx > 0.05 && spot == null; fx -= 0.05) {
          for (final fy in [0.5, 0.2, 0.8]) {
            final p = Offset(r.left + r.width * fx, r.top + r.height * fy);
            if (!plot.contains(p)) continue;
            if (dots.every((d) => (d - p).distance > radius + 1)) {
              spot = p;
              dot = c;
              break;
            }
          }
        }
        if (spot != null) break;
      }
      expect(spot, isNotNull, reason: 'a label reaches past the hit radius');
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      List<String> texts() => [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: tip, matching: find.byType(Text)),
        ))
          t.data ?? '',
      ];
      Future<void> settle() =>
          tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      if (kind == PointerDeviceKind.mouse) {
        // Hovering the label shows it too, as hovering the dot does.
        final mouse = await tester.createGesture(kind: kind);
        await mouse.addPointer(location: origin + spot!);
        await mouse.moveTo(origin + spot + const Offset(0.5, 0));
        await tester.pump();
        expect(tip, findsOneWidget, reason: 'hover on the label');
        await mouse.moveTo(origin + plot.topLeft + const Offset(4, 4));
        await tester.pump();
        await mouse.removePointer();
        await tester.pump();
      }
      await tester.tapAt(origin + spot!, kind: kind);
      await tester.pump();
      expect(tip, findsOneWidget, reason: 'tap on the label');
      final byLabel = texts();
      final rectByLabel = tester.getRect(tip);
      await settle();
      // Dismiss, then tap the dot itself: the same popup in the same place.
      await tester.tapAt(
        origin + plot.topLeft + const Offset(4, 4),
        kind: kind,
      );
      await tester.pump();
      await settle();
      expect(tip, findsNothing);
      await tester.tapAt(origin + dot!, kind: kind);
      await tester.pump();
      expect(tip, findsOneWidget);
      expect(texts(), byLabel);
      expect(tester.getRect(tip), rectByLabel);
      await settle();
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('320px phone: the long ordinal date fits the pill and popup', (
    tester,
  ) async {
    await _pump(tester, size: const Size(320, 640));
    await _revealTip(tester, PointerDeviceKind.touch);
    final chart = tester.getRect(find.byType(BalanceChart));
    final pill = tester.getRect(find.byKey(const ValueKey('x-highlight')));
    expect(pill.left, greaterThanOrEqualTo(chart.left));
    expect(pill.right, lessThanOrEqualTo(chart.right));
    final date = tester
        .widgetList<Text>(find.byKey(const ValueKey('tip-date')))
        .first;
    expect(date.data, matches(RegExp(r'day \d{1,2}(st|nd|rd|th) ')));
    expect(date.overflow, TextOverflow.ellipsis);
    final tip = tester.getRect(
      find.byKey(const ValueKey('occurrence-tooltip')),
    );
    expect(tip.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });
}

/// The heatmap's start label without any year ("9 Oct").
String _rangeStart(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('range-start')))
    .data!
    .split(' ')
    .take(2)
    .join(' ');

/// Year of the heatmap's start day (from the chart's view).
int _firstYear(WidgetTester tester) {
  final c = tester.widget<BalanceChart>(find.byType(BalanceChart));
  final w = tester.getSize(find.byType(BalanceChart)).width;
  final inset = ChartLayout.laneNameWidth(w) * c.visibleDays / w;
  return dateFromDayCoord((dayCoord(c.viewStart) + inset - 1e-6).ceilToDouble())
      .year;
}

DateTime _plus(DateTime x, int days) => DateTime(x.year, x.month, x.day + days);

void _three(_Store s) {
  final r = s.txs['rent']!;
  s.txs['gym'] = Transaction(
    id: 'gym',
    poolId: r.poolId,
    name: 'Gym',
    direction: TransactionDirection.debit,
    amount: Decimal.fromInt(25),
    startDate: r.startDate,
    recurrenceMode: RecurrenceMode.once,
    endMode: EndMode.never,
  );
}

/// Popup compactness: 1-row and 3-row cards stay well under the old
/// stacked layout (280x124 / 280x228 on touch, 280x112 / 280x204 mouse).
void popupSizeProbe() {
  for (final (size, kind) in [
    (const Size(390, 844), PointerDeviceKind.touch),
    (const Size(1440, 900), PointerDeviceKind.mouse),
    (const Size(320, 640), PointerDeviceKind.touch),
  ]) {
    final touch = kind == PointerDeviceKind.touch;
    for (final (rows, setup, maxH) in [
      (1, _singles, touch ? 96.0 : 80.0),
      (3, _three, touch ? 140.0 : 110.0),
    ]) {
      testWidgets('popup is compact: ${size.width.toInt()} ${kind.name} '
          '$rows row(s)', (tester) async {
        await _pump(tester, size: size, setup: setup);
        await _revealTip(tester, kind);
        final r = tester.getRect(
          find.byKey(const ValueKey('occurrence-tooltip')),
        );
        expect(r.width, lessThanOrEqualTo(280));
        expect(r.height, lessThanOrEqualTo(maxH));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(size.width));
        if (rows == 1) expect(r.width, lessThan(280), reason: 'hugs content');
      });
    }
  }
}
