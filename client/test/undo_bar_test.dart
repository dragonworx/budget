// The floating Undo bar after every trim path: a lane / dot menu's (or a
// day popup row's ⋮) Trim From Here on a series, the same trim when it
// leaves nothing (it deletes), and the day pick's ✂ batch. Each shows the
// one shared bar (key undo-tip) clear of the screen edge and bottom safe
// area, above an open day popup, for 5s, and its Undo restores; a newer
// trim replaces the bar at once.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/editor_outcome.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/timeline/trim.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.now();
final _day = DateTime(_now.year, _now.month, _now.day);

BudgetEvent _ev(
  String id,
  String name, {
  String? color,
  DateTime? start,
  RecurrenceMode mode = RecurrenceMode.every,
  EndMode end = EndMode.never,
  DateTime? endDate,
  bool enabled = true,
  TransferLink? transfer,
}) => BudgetEvent(
  id: id,
  streamId: 'acc',
  name: name,
  direction: EventDirection.debit,
  amount: Decimal.fromInt(50),
  startDate: start ?? _day.subtract(const Duration(days: 14)),
  recurrenceMode: mode,
  interval: mode == RecurrenceMode.every ? 1 : null,
  unit: mode == RecurrenceMode.every ? RecurrenceUnit.weeks : null,
  endMode: end,
  endDate: endDate,
  enabled: enabled,
  color: color,
  transfer: transfer,
);

class _Store {
  final txs = <String, BudgetEvent>{
    'rent': _ev('rent', 'Rent'),
    'gym': _ev('gym', 'Gym', color: '#3C8A6E'),
    'once': _ev(
      'once',
      'Once',
      mode: RecurrenceMode.once,
      start: _day.add(const Duration(days: 3)),
    ),
  };
  Role role = Role.owner;
  final calls = <String>[];
  final created = <BudgetEvent>[];
  final updated = <BudgetEvent>[];
  Map<String, BudgetEvent>? beforeBatch;
}

class _StreamRepo extends StreamRepository {
  _StreamRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<BudgetStream> get(String id) async => BudgetStream(
    id: 'acc',
    ownerId: 'u',
    name: 'Everyday',
    seedBalance: Decimal.fromInt(1000),
    seedDate: _day.subtract(const Duration(days: 30)),
    lossThreshold: Decimal.zero,
    currencyScale: 100,
    role: s.role,
    eventOrder: s.txs.keys.toList(),
  );

  @override
  Future<BudgetStream> reorderEvents(
    String streamId,
    List<String> eventIds,
  ) async {
    s.calls.add('reorder ${eventIds.join(',')}');
    return get(streamId);
  }

  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async => BalanceSeries(
    points: [
      for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
        BalancePoint(date: d, closingBalance: Decimal.fromInt(1000)),
    ],
    occurrences: const [],
  );
}

class _EventRepo extends EventRepository {
  _EventRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      s.txs.values.toList();

  @override
  Future<BudgetEvent> create(String streamId, BudgetEvent draft) async {
    s.created.add(draft);
    return s.txs[draft.id] = draft;
  }

  @override
  Future<void> delete(String id) async {
    s.calls.add('delete $id');
    s.txs.remove(id);
  }

  @override
  Future<BudgetEvent> update(BudgetEvent t, {bool force = false}) async {
    s.updated.add(t);
    return s.txs[t.id] = t;
  }

  @override
  Future<
    ({
      String? batchId,
      List<String> ended,
      List<String> deleted,
      List<String> blocked,
    })
  >
  endAllOn(String streamId, DateTime day, {List<String>? ids}) async {
    s.calls.add('endAllOn ${formatDate(day)} ${ids?.join(',')}');
    s.beforeBatch = {...s.txs};
    final ended = <String>[], deleted = <String>[];
    for (final id in ids ?? s.txs.keys.toList()) {
      final t = s.txs[id]!;
      switch (endOnDay(t, day)) {
        case DayTrim.end:
          s.txs[id] = trimmedEvent(t, day);
          ended.add(id);
        case DayTrim.delete:
          s.txs.remove(id);
          deleted.add(id);
        case null:
      }
    }
    return (
      batchId: 'batch-1',
      ended: ended,
      deleted: deleted,
      blocked: <String>[],
    );
  }

  @override
  Future<void> undoEndAllOn(String streamId, String batchId) async {
    s.calls.add('undo $batchId');
    s.txs
      ..clear()
      ..addAll(s.beforeBatch!);
  }
}

Future<_Store> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  void Function(_Store)? setup,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = _Store();
  setup?.call(store);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_StreamRepo(store)),
        eventRepositoryProvider.overrideWithValue(_EventRepo(store)),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const TimelinePage(streamId: 'acc'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

BalanceChart _chart(WidgetTester tester) =>
    tester.widget<BalanceChart>(find.byType(BalanceChart));

final _tip = find.byKey(const ValueKey('undo-tip'));

String _tipText(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: _tip, matching: find.byType(Text)))
    .first
    .data!;

Future<void> _openPick(WidgetTester tester, PointerDeviceKind kind) async {
  final chart = tester.getRect(find.byType(BalanceChart));
  await tester.tapAt(Offset(chart.center.dx, chart.bottom - 8), kind: kind);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
}

/// The bar is up, on screen, clear of the bottom safe area, and its Undo
/// is the topmost thing at its spot (not under a popup or menu).
void _expectBar(WidgetTester tester, Size size, double safeBottom) {
  expect(_tip, findsOneWidget);
  // The bar itself (the SnackBar widget spans its margin and the inset).
  final r = tester.getRect(
    find.descendant(of: _tip, matching: find.byType(Material)).first,
  );
  expect(r.left, greaterThanOrEqualTo(8), reason: 'a margin, on screen');
  expect(r.right, lessThanOrEqualTo(size.width - 8));
  expect(r.top, greaterThan(size.height / 2), reason: 'floats at the bottom');
  expect(r.bottom, lessThanOrEqualTo(size.height - safeBottom + 0.5));
  final undo = find.descendant(of: _tip, matching: find.text('Undo'));
  expect(undo.hitTestable(), findsOneWidget, reason: 'Undo can be tapped');
}

/// The trim's async save, then the bar's entrance.
Future<void> _settleBar(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapUndo(WidgetTester tester) async {
  await tester.tap(find.descendant(of: _tip, matching: find.text('Undo')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(find.text('Undone'), findsOneWidget);
}

void main() {
  for (final (size, kind, safe, label) in const [
    (Size(390, 844), PointerDeviceKind.touch, 34.0, 'iPhone (safe area)'),
    (Size(412, 915), PointerDeviceKind.touch, 0.0, 'phone'),
    (Size(1440, 900), PointerDeviceKind.mouse, 0.0, 'desktop'),
  ]) {
    Future<_Store> pumpAt(WidgetTester tester) async {
      tester.view.padding = FakeViewPadding(bottom: safe);
      tester.view.viewPadding = FakeViewPadding(bottom: safe);
      final store = await _pump(tester, size: size);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      return store;
    }

    testWidgets('$label: Trim From Here on a series (lane / dot menu, a '
        'popup row ⋮) shows the Undo bar over the open popup; it stays '
        '5s; Undo restores the end', (tester) async {
      final store = await pumpAt(tester);
      await _openPick(tester, kind);
      final cut = _day.add(const Duration(days: 7));
      _chart(tester).onTrimOccurrence!(store.txs['rent']!, cut);
      await _settleBar(tester);
      final end = cut.subtract(const Duration(days: 1));
      expect(store.txs['rent']!.endMode, EndMode.untilDate);
      expect(store.txs['rent']!.endDate, end);
      _expectBar(tester, size, safe);
      expect(
        _tipText(tester),
        'Trimmed “Rent” · ends ${formatOccurrenceDate(end)}',
      );
      await tester.pump(const Duration(seconds: 3));
      expect(_tip, findsOneWidget, reason: 'still up 3.4s on');
      await _tapUndo(tester);
      expect(store.txs['rent']!.endMode, EndMode.never);
      expect(store.txs['rent']!.endDate, isNull);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Undone'), findsNothing);
    });

    testWidgets('$label: a trim that leaves nothing asks, deletes, and '
        'shows the same bar; Undo brings the event back', (tester) async {
      final store = await pumpAt(tester);
      final once = store.txs['once']!;
      _chart(tester).onTrimOccurrence!(once, once.startDate);
      await tester.pumpAndSettle();
      expect(find.text('Delete Once?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _settleBar(tester);
      expect(store.txs.containsKey('once'), isFalse);
      _expectBar(tester, size, safe);
      expect(_tipText(tester), 'Deleted “Once”');
      await _tapUndo(tester);
      expect(store.txs.values.map((t) => t.name), contains('Once'));
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('$label: the day pick ✂ batch shows the same bar over the '
        'popup; Undo undoes the batch', (tester) async {
      final store = await pumpAt(tester);
      await _openPick(tester, kind);
      await tester.tap(find.byKey(const ValueKey('pick-trim')), kind: kind);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'End all'));
      await _settleBar(tester);
      expect(store.calls.where((c) => c.startsWith('endAllOn')), hasLength(1));
      _expectBar(tester, size, safe);
      expect(_tipText(tester), startsWith('Ended '));
      await _tapUndo(tester);
      expect(store.calls.last, 'undo batch-1');
      expect(store.txs['rent']!.endMode, EndMode.never);
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('a newer trim replaces the bar at once (one bar, the newest '
      'text); its Undo undoes only the newer trim; the bar hides after 5s', (
    tester,
  ) async {
    final store = await _pump(tester, size: const Size(390, 844));
    final cut = _day.add(const Duration(days: 7));
    _chart(tester).onTrimOccurrence!(store.txs['rent']!, cut);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_tipText(tester), startsWith('Trimmed “Rent”'));
    _chart(tester).onTrimOccurrence!(store.txs['gym']!, cut);
    await tester.pump();
    expect(_tip, findsOneWidget, reason: 'no queue behind the old bar');
    expect(_tipText(tester), startsWith('Trimmed “Gym”'));
    await tester.pump(const Duration(milliseconds: 400));
    await _tapUndo(tester);
    expect(store.txs['gym']!.endMode, EndMode.never);
    expect(
      store.txs['rent']!.endMode,
      EndMode.untilDate,
      reason: 'the replaced bar\'s trim stays',
    );
    // A fresh trim: up for 5s, then gone, whatever is open.
    _chart(tester).onTrimOccurrence!(store.txs['gym']!, cut);
    await tester.pump();
    expect(_tip, findsOneWidget, reason: 'replaces "Undone" at once');
    await tester.pump(const Duration(milliseconds: 4500));
    expect(_tip, findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_tip, findsNothing);
    expect(trimFromHere(store.txs['gym']!, cut), isNull);
  });

  testWidgets('the bar\'s backstop timer is harmless once its messenger is '
      'gone (the events panel that showed it was closed)', (tester) async {
    final key = GlobalKey<ScaffoldMessengerState>();
    final open = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: open,
          builder: (_, isOpen, _) => isOpen
              ? ScaffoldMessenger(
                  key: key,
                  child: const Scaffold(body: SizedBox()),
                )
              : const SizedBox(),
        ),
      ),
    );
    showUndoBar(key.currentState!, text: 'Created "X"', onUndo: () async {});
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('undo-tip')), findsOneWidget);
    open.value = false;
    await tester.pump();
    await tester.pump(undoTipDuration + const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
