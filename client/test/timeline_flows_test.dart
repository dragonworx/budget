import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

final _today = DateTime.now();
final _day = DateTime(_today.year, _today.month, _today.day);

Account _account() => Account(
  id: 'acc',
  projectId: 'p',
  name: 'Everyday',
  currency: 'AUD',
  seedBalance: Decimal.fromInt(1000),
  seedDate: _day.subtract(const Duration(days: 30)),
  lossThreshold: Decimal.zero,
  currencyScale: 1000,
);

Transaction _tx(String id, String name, {TransactionDirection? dir}) =>
    Transaction(
      id: id,
      accountId: 'acc',
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
}

class _AccountRepo extends AccountRepository {
  _AccountRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<Account> get(String id) async => _account();

  @override
  Future<BalanceSeries> balance(
    String accountId, {
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
  Future<List<Transaction>> listForAccount(String accountId) async =>
      s.txs.values.toList();

  @override
  Future<Transaction> update(Transaction t) async {
    s.calls.add('update ${t.id} ${t.interval} ${t.unit?.name}');
    return s.txs[t.id] = t;
  }

  @override
  Future<Transaction> create(String accountId, Transaction draft) async {
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  // The test font (Ahem) is much wider than the app's fonts.
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = _Store();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        accountRepositoryProvider.overrideWithValue(_AccountRepo(store)),
        transactionRepositoryProvider.overrideWithValue(_TxRepo(store)),
      ],
      child: const MaterialApp(home: TimelinePage(accountId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return store;
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
    // Rent is weekly: the preset shows; switch to Fortnightly.
    await tester.tap(find.byKey(const ValueKey('editor-frequency-weekly')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fortnightly').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-interval')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('update rent 2 weeks'));
    expect(find.text('Saved “Rent”'), findsOneWidget);
    expect(
      store.calls.where((c) => c == 'balance').length,
      greaterThan(balanceCalls),
    );
    expect(find.byKey(const ValueKey('focus-banner')), findsNothing);
    await tester.pump(const Duration(seconds: 3));
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
    await tester.pump(const Duration(seconds: 2));
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
      expect(find.text('Account settings'), findsOneWidget);
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
      await tester.pump(const Duration(seconds: 2));
    });
  }

  testWidgets('unit dropdown, − / + and ◀ ▶ snap the view instantly', (
    tester,
  ) async {
    await _pump(tester);
    BalanceChart chart() =>
        tester.widget<BalanceChart>(find.byType(BalanceChart));
    expect(find.text('Month'), findsOneWidget);
    // Opens centred on today (not aligned); ▶ snaps to a month start.
    final open = chart().viewStart;
    final mid = dayCoord(open) + chart().visibleDays / 2;
    expect(mid, inInclusiveRange(dayCoord(_day), dayCoord(_day) + 1));
    await tester.tap(find.byKey(const ValueKey('shift-right')));
    await tester.pump();
    final start = chart().viewStart;
    expect(start.day, 1);
    await tester.tap(find.byKey(const ValueKey('shift-right')));
    await tester.pump();
    expect(chart().viewStart, DateTime(start.year, start.month + 1));
    await tester.tap(find.byKey(const ValueKey('shift-left')));
    await tester.tap(find.byKey(const ValueKey('shift-left')));
    await tester.pump();
    expect(chart().viewStart, DateTime(start.year, start.month - 1));
    double center() =>
        dayCoord(chart().viewStart) + chart().visibleDays / 2;
    final c0 = center();
    // Compress (zoom out) sits on the left, stretch (zoom in) on the right.
    expect(
      tester.getCenter(find.byKey(const ValueKey('x-scale-out'))).dx,
      lessThan(tester.getCenter(find.byKey(const ValueKey('span-label'))).dx),
    );
    expect(
      tester.getCenter(find.byKey(const ValueKey('x-scale-in'))).dx,
      greaterThan(
          tester.getCenter(find.byKey(const ValueKey('span-label'))).dx),
    );
    await tester.tap(find.byKey(const ValueKey('x-scale-in')));
    await tester.pump();
    expect(find.text('3 weeks'), findsOneWidget); // label switches at once
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-ease: between the two spans, same centre date.
    expect(chart().visibleDays, inExclusiveRange(21, 31));
    expect(center(), closeTo(c0, 1e-6));
    await tester.pumpAndSettle();
    expect(chart().visibleDays, closeTo(21, 1e-9));
    expect(center(), closeTo(c0, 1e-6));
    // Rapid taps chain from the animated state and still keep the centre.
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byKey(const ValueKey('x-scale-out')));
      await tester.pump(const Duration(milliseconds: 40));
      expect(center(), closeTo(c0, 1e-6));
    }
    await tester.pumpAndSettle();
    expect(find.text('Year'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const ValueKey('x-scale-out')))
          .onPressed,
      isNull,
    );
    expect(chart().visibleDays, anyOf(365, 366));
    expect(center(), closeTo(c0, 1e-6));
    // ◀ ▶ stay instant and unit-snapped.
    await tester.tap(find.byKey(const ValueKey('shift-left')));
    await tester.pump();
    expect(chart().viewStart.month, 1);
    expect(chart().viewStart.day, 1);
  });

  testWidgets('y-scale buttons ease the balance axis, never the time range', (
    tester,
  ) async {
    await _pump(tester);
    BalanceChart chart() =>
        tester.widget<BalanceChart>(find.byType(BalanceChart));
    final start = chart().viewStart;
    final days = chart().visibleDays;
    for (final key in ['y-scale-in', 'y-scale-in', 'y-scale-out']) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump(const Duration(milliseconds: 60));
      expect(chart().viewStart, start);
      expect(chart().visibleDays, days);
    }
    await tester.pumpAndSettle();
    expect(chart().viewStart, start);
    expect(chart().visibleDays, days);
    expect(tester.takeException(), isNull);
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
    expect(text.data, startsWith('A\$'));
    expect(text.style?.fontWeight, FontWeight.w800);
    await tester.pump(const Duration(seconds: 10));
    expect(pill, findsOneWidget, reason: 'stays while pinned');
    // A zoom button clears it (and the popup).
    await tester.tap(find.byKey(const ValueKey('y-scale-out')));
    await tester.pump();
    expect(pill, findsNothing);
    expect(tip, findsNothing);
    await tester.pumpAndSettle();
    // ◀ ▶ shift clears it.
    await reveal();
    expect(pill, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shift-right')));
    await tester.pump();
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
    final g2 = await tester.startGesture(
      spot,
      kind: PointerDeviceKind.touch,
    );
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
    for (var fx = 0.0; fx < 0.9 && !found; fx += 0.01) {
      for (var fy = 0.05; fy < 0.85 && !found; fy += 0.04) {
        await tester.tapAt(
          Offset(
            plot.left + 112 + (plot.width - 140) * fx,
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
}
