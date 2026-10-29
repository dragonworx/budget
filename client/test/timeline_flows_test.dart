import 'dart:async';
import 'dart:math' as math;

import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/features/events/import_dialog.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/widgets/ui.dart' show SectionCard;
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/planning/goal_models.dart';
import 'package:budget_client/features/planning/plan_panel.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/occurrence_dates.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/features/timeline/selection_period.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:budget_client/widgets/list_glyph.dart';
import 'package:budget_client/widgets/day_add_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/features/timeline/fit_ranges.dart';
import 'package:budget_client/widgets/eye_icons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chip_taps.dart';

import 'support/fake_categories.dart';

final _today = DateTime.now();
final _day = DateTime(_today.year, _today.month, _today.day);

BudgetStream _stream({Role role = Role.owner}) => BudgetStream(
  id: 'acc',
  ownerId: 'u',
  name: 'Everyday',
  seedBalance: Decimal.fromInt(1000),
  seedDate: _day.subtract(const Duration(days: 30)),
  lossThreshold: Decimal.zero,
  currencyScale: 1000,
  role: role,
);

BudgetEvent _tx(String id, String name, {EventDirection? dir}) => BudgetEvent(
  id: id,
  streamId: 'acc',
  name: name,
  direction: dir ?? EventDirection.debit,
  amount: Decimal.fromInt(id == 'salary' ? 4200 : 50),
  startDate: _day.subtract(const Duration(days: 14)),
  recurrenceMode: RecurrenceMode.every,
  interval: 1,
  unit: RecurrenceUnit.weeks,
  endMode: EndMode.never,
);

BudgetEvent _withOverrides(
  BudgetEvent t,
  Map<DateTime, OccurrenceOverride> overrides,
) => BudgetEvent(
  id: t.id,
  streamId: t.streamId,
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

/// In-memory server: events, skips and a flat balance.
class _Store {
  final txs = <String, BudgetEvent>{
    'rent': _tx('rent', 'Rent'),
    'salary': _tx('salary', 'Salary', dir: EventDirection.credit),
  };
  final skips = <String, Set<DateTime>>{};
  final calls = <String>[];
  Role role = Role.owner;
  bool undoFails = false;
  final goals = <GoalRequest>[];
  final solves = <SolveRequest>[];
}

class _StreamRepo extends StreamRepository {
  _StreamRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<BudgetStream> get(String id) async => _stream(role: s.role);

  // The planner: both modes keep their own server call.
  @override
  Future<GoalResult> goal(String streamId, GoalRequest request) async {
    s.goals.add(request);
    return GoalResult.fromJson({
      'status': 'incomplete',
      'solveFor': request.solveFor.name,
      'needsOneOf': ['targetBalance'],
    });
  }

  @override
  Future<SolveResult> solve(String streamId, SolveRequest request) async {
    s.solves.add(request);
    return SolveResult.fromJson({
      'status': 'incomplete',
      'solved': <String>[],
      'values': {'interval': 1},
      'needsMore': 2,
      'needsOneOf': ['total', 'amount'],
    });
  }

  @override
  Future<BalanceSeries> balance(
    String streamId, {
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
        final sign = t.direction == EventDirection.credit ? 1 : -1;
        occ.add(
          Occurrence(
            eventId: t.id,
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

class _TxRepo extends EventRepository {
  _TxRepo(this.s) : super(ApiClient());
  final _Store s;

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      s.txs.values.toList();

  @override
  Future<BudgetEvent> update(BudgetEvent t, {bool force = false}) async {
    s.calls.add('update ${t.id} ${t.interval} ${t.unit?.name}');
    // Like the server: overrides no longer on an occurrence are pruned.
    final end = t.endMode == EndMode.untilDate ? t.endDate : null;
    return s.txs[t.id] = _withOverrides(t, {
      for (final e in t.overrides.entries)
        if (end == null || !e.key.isAfter(end)) e.key: e.value,
    });
  }

  @override
  Future<BudgetEvent> setOverride(
    String eventId,
    DateTime date, {
    required EventDirection direction,
    required Decimal amount,
    int? version,
  }) async {
    s.calls.add('override $eventId');
    final t = s.txs[eventId]!;
    return s.txs[eventId] = _withOverrides(t, {
      ...t.overrides,
      date: OccurrenceOverride(direction: direction, amount: amount),
    });
  }

  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    s.calls.add('create ${draft.name}');
    return s.txs[draft.id] = draft;
  }

  @override
  Future<Map<String, dynamic>> import(
    String streamId,
    String raw, {
    required DateTime root,
    bool dryRun = false,
  }) async {
    s.calls.add('import ${importRootParam(root)} dryRun=$dryRun');
    return dryRun
        ? {
            'items': [
              {
                'name': 'Bonus',
                'direction': 'credit',
                'amount': '5',
                'startDate': importRootParam(root),
                'recurrenceMode': 'once',
                'skippedDates': <String>[],
              },
            ],
            'toCreate': 1,
            'toSkip': 0,
          }
        : {
            'created': 1,
            'skipped': 0,
            'createdIds': ['imp-${s.calls.length}'],
          };
  }

  @override
  Future<Map<String, dynamic>> undoImport(
    String streamId,
    List<String> ids,
  ) async {
    s.calls.add('undoImport ${ids.join(',')}');
    if (s.undoFails) throw ApiException('Server unavailable', statusCode: 503);
    return {'deleted': ids.length, 'deletedIds': ids, 'missing': <String>[]};
  }

  @override
  Future<BudgetEvent> setEnabled(String id, bool enabled) async {
    s.calls.add('enabled $id=$enabled');
    final t = s.txs[id]!.copyWith(enabled: enabled);
    s.txs[id] = t;
    return t;
  }

  @override
  Future<void> delete(String id) async {
    s.calls.add('delete $id');
    s.txs.remove(id);
  }

  @override
  Future<void> skipOccurrence(
    String eventId,
    DateTime date, {
    bool skipped = true,
  }) async {
    s.calls.add('skip $eventId $skipped');
    final set = s.skips.putIfAbsent(eventId, () => {});
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
        streamRepositoryProvider.overrideWithValue(_StreamRepo(store)),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
        ),
        eventRepositoryProvider.overrideWithValue(_TxRepo(store)),
      ],
      child: const MaterialApp(home: TimelinePage(streamId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Taps (touch or mouse click) across the plot until a popup (a net
/// chip's: lanes only reveal their dot) shows;
/// returns where.
Future<Offset> _revealTip(WidgetTester tester, PointerDeviceKind kind) =>
    // Lanes only reveal their dot (its click opens the action menu): the
    // popup comes from a day's net chip.
    revealDayTip(
      tester,
      kind,
      shown: () => find
          .byKey(const ValueKey('occurrence-tooltip'))
          .evaluate()
          .isNotEmpty,
    );

/// Salary a day after Rent, so every dot holds one event.
void _singles(_Store s) {
  final t = s.txs['salary']!;
  s.txs['salary'] = t.copyWith(
    startDate: t.startDate.add(const Duration(days: 1)),
  );
}

/// Opens the ⋮ menu of the popup row for event [id].
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

/// Opens [name]'s series in the editor through the Events panel
/// (the only edit path: taps on the chart just show info).
Future<void> _editFromPanel(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('open-events')));
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
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
      expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
      // Drag along the footer and release: still only the line.
      final g = await tester.startGesture(footer, kind: kind);
      for (var i = 1; i <= 5; i++) {
        await g.moveTo(footer + Offset(i * 10.0, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
      expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pick-add')), kind: kind);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
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
    expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
    expect(find.text('New event'), findsWidgets);
    String fmt(DateTime d) => DateFormat('EEE d MMM y').format(d);
    expect(find.text(fmt(start)), findsWidgets, reason: 'start pre-filled');
    // Once by default (every entry point); Repeats ends on the period's
    // last day.
    expect(find.byType(SegmentedButton<EndMode>), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('editor-freq-weekly')),
    );
    await tester.tap(find.byKey(const ValueKey('editor-freq-weekly')));
    await tester.pumpAndSettle();
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

  testWidgets('mouse hover on a net chip (or an always-drawn dot) shows '
      'the info popup; away hides it', (tester) async {
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

  for (final (size, kind) in const [
    (Size(1440, 900), PointerDeviceKind.mouse),
    (Size(390, 844), PointerDeviceKind.touch),
  ]) {
    testWidgets('${kind.name}: a tap / click on an event lane opens its '
        'menu at once (no popup, no reveal step); New Event From Here opens '
        'the editor on that day and only Save creates', (tester) async {
      final placed = <(String?, Offset)>[];
      debugLaneDot = (id, c) => placed.add((id, c));
      addTearDown(() => debugLaneDot = null);
      final store = await _pump(tester, size: size, setup: _singles);
      debugLaneDot = null;
      store.calls.clear();
      final chart = tester.getRect(find.byType(BalanceChart));
      final rentDates = estimateOccurrenceDates(
        store.txs['rent']!,
        maxCount: 400,
      );
      // A Rent dot clear of the edges.
      final dot = placed
          .where(
            (p) =>
                p.$1 == 'rent' &&
                p.$2.dx > chart.width * 0.3 &&
                p.$2.dx < chart.width * 0.8,
          )
          .first
          .$2;
      final tip = find.byKey(const ValueKey('occurrence-tooltip'));
      final at = chart.topLeft + dot;
      if (kind == PointerDeviceKind.mouse) {
        final mouse = await tester.createGesture(kind: kind);
        await mouse.addPointer(location: at + const Offset(30, 1));
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(tip, findsNothing, reason: 'no hover popup');
        await mouse.moveTo(at);
        await tester.pump();
        await mouse.down(at);
        await mouse.up();
      } else {
        // On the lane just right of its (hidden) dot: the menu, at once.
        await tester.tapAt(at + const Offset(4, 0), kind: kind);
      }
      await tester.pumpAndSettle();
      expect(tip, findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('dot-menu-name'))).data,
        'Rent',
      );
      expect(find.text('New Event From Here'), findsOneWidget);
      expect(find.text('Trim From Here'), findsOneWidget);
      expect(find.text('Edit Series'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dot-menu-new')), kind: kind);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
      // The start is one of Rent's days (the dot's).
      final shown = [
        for (final d in rentDates)
          if (find.text(formatOccurrenceDate(d)).evaluate().isNotEmpty) d,
      ];
      expect(shown, hasLength(1), reason: 'start pre-filled to the dot');
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
          matching: find.byType(TextField),
        ),
        '4',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('editor-save')));
      await tester.tap(find.byKey(const ValueKey('editor-save')));
      await tester.pumpAndSettle();
      expect(store.calls, contains('create Rent'));
      final made = store.txs.values.last;
      expect(made.startDate, shown.single);
      await tester.pump(const Duration(seconds: 6));
    });
  }

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
    expect(
      tester.widget<EventEditor>(find.byType(EventEditor)).existing?.name,
      'Salary',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('editing the frequency saves and refreshes the timeline', (
    tester,
  ) async {
    final store = await _pump(tester);
    await _editFromPanel(tester, 'Rent');
    final balanceCalls = store.calls.where((c) => c == 'balance').length;
    // Rent is weekly; pick Every N weeks (starts at 2).
    expect(_phrase(tester), startsWith('Every week'));
    await tester.ensureVisible(
      find.byKey(const ValueKey('editor-freq-every_n_weeks')),
    );
    await tester.tap(find.byKey(const ValueKey('editor-freq-every_n_weeks')));
    await tester.pumpAndSettle();
    expect(_phrase(tester), startsWith('Every 2 weeks'));
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
    expect(find.byTooltip('Events (2)'), findsOneWidget);
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
    expect(find.byTooltip('Events (1)'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    expect(find.byTooltip('Events (2)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('unsaved edits ask before discarding', (tester) async {
    await _pump(tester);
    await _editFromPanel(tester, 'Rent');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(TextField),
      ),
      '999',
    );
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-save')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('events panel opens the editor in place, back returns', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salary'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-back')), findsOneWidget);
    // Only one panel route: the list is replaced, not stacked.
    expect(find.byKey(const ValueKey('events-category-filter')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('events-category-filter')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('events-category-filter')), findsNothing);
  });

  testWidgets('new event button creates and the count updates', (tester) async {
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-new-event')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(TextField),
      ),
      '4.5',
    );
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('create Rent'));
    expect(find.text('Created “Rent”'), findsOneWidget);
    expect(find.byTooltip('Events (3)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  for (final size in const [Size(360, 740), Size(375, 812), Size(412, 839)]) {
    testWidgets('phone ${size.width.toInt()}px: compact header, no overflow, '
        'panel creates', (tester) async {
      final store = await _pump(tester, size: size);
      // Layout overflows surface as test exceptions; none expected.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('new-event')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-back')), findsOneWidget);
      final back = tester.getSize(find.byKey(const ValueKey('timeline-back')));
      expect(back.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(find.text('Stream settings'), findsOneWidget);
      expect(find.text('Import events'), findsOneWidget);
      await tester.tapAt(const Offset(5, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('panel-new-event')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
      expect(store.calls, contains('create Rent'));
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
        // Both fingers must reach the chart: clear of the popup.
        final popup = find.byKey(const ValueKey('occurrence-tooltip'));
        if (tip.evaluate().isNotEmpty &&
            popup.evaluate().isNotEmpty &&
            !tester.getRect(popup).inflate(50).contains(p) &&
            !tester
                .getRect(popup)
                .inflate(50)
                .contains(p + const Offset(0, 40))) {
          spot = p;
        }
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
    // Lane dots are hidden until a tap reveals one; then a drag along its
    // lane scrubs, and on lift the tip stays on the last dot.
    await tester.tapAt(spot!, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(tip, findsOneWidget);
    final g = await tester.startGesture(spot, kind: PointerDeviceKind.touch);
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
      // A net chip's popup (lane reveals draw no guides).
      // (one clear of the edges, so the pill is not clamped).
      Future<void> reveal() => revealDayTip(
        tester,
        kind,
        shown: () {
          if (tip.evaluate().isEmpty || col.evaluate().isEmpty) return false;
          final x = tester.getCenter(col).dx;
          return x > chart.left + chart.width * 0.3 &&
              x < chart.right - chart.width * 0.3;
        },
      );

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

  testWidgets('popup ⋮ → Edit (one event) opens its editor; the ⋮ '
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
      expect(m.width, closeTo(touch ? 44 : 28, 0.01));
      expect(m.height, closeTo(touch ? 44 : 28, 0.01));
      // A tap on the card itself (not ⋮) does nothing and keeps it up.
      final card = tester.getRect(tip);
      await tester.tapAt(card.topLeft + const Offset(20, 12), kind: kind);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tip, findsOneWidget);
      // Opening the menu keeps the popup; nothing opens yet.
      await _openRowMenu(tester, id, kind);
      expect(tip, findsOneWidget, reason: 'popup stays behind its menu');
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
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
      expect(find.text('Trim From Here'), findsOneWidget);
      expect(find.text('Trim'), findsNothing);
      expect(
        find.descendant(
          of: _keyStarts('tip-menu-new-'),
          matching: find.text('New'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('New event on '), findsNothing);
      await tester.tap(items[2], kind: kind);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EventEditor>(find.byType(EventEditor)).existing?.name,
        name,
      );
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
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
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
    expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('popup with several events: one compact line each '
      '(name, amount, ⋮); ⋮ → Edit opens that series', (tester) async {
    for (final (size, kind) in [
      (const Size(390, 844), PointerDeviceKind.touch),
      (const Size(1440, 900), PointerDeviceKind.mouse),
      (const Size(320, 640), PointerDeviceKind.touch),
    ]) {
      final store = await _pump(tester, size: size);
      await revealDayTip(tester, kind);
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
      expect(
        tester.widget<EventEditor>(find.byType(EventEditor)).existing?.name,
        'Salary',
      );
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
      );
    }
  });

  testWidgets('popup "+" opens a new event on that day (Name focused, '
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
        find.descendant(of: plus, matching: find.text('New')),
        findsOneWidget,
      );
      expect(find.textContaining('New event on '), findsNothing);
      final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
      final txDay = chart.series.occurrences
          .map((o) => DateTime(o.date.year, o.date.month, o.date.day))
          .firstWhere((d) => formatSelectedDate(d) == tipText);
      final primed = page.primeSoftKeyboardCalls;
      await tester.tap(plus, kind: kind);
      await tester.pumpAndSettle();
      expect(page.primeSoftKeyboardCalls, primed + 1);
      final name = find.descendant(
        of: find.byKey(const ValueKey('editor-amount')),
        matching: find.byType(TextField),
      );
      expect(name, findsOneWidget);
      expect(tester.widget<TextField>(name).controller?.text, isEmpty);
      expect(
        tester.widget<TextField>(name).focusNode?.hasFocus ?? true,
        isTrue,
      );
      // The editor's date is the dot's day.
      final editor = tester.widget<EventEditor>(find.byType(EventEditor));
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
    // Reveal the dot again, drag-scrub along its lane, then lift: same rect
    // just before and after up.
    await tester.tapAt(spot!, kind: PointerDeviceKind.touch);
    await tester.pump();
    final g = await tester.startGesture(spot, kind: PointerDeviceKind.touch);
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
    await tester.tap(find.byKey(const ValueKey('open-events')));
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

  // ── New event: Name focused (phones too); Once by default, no
  // Occurrences / Options; Repeats starts at every 1 week ──

  List<String> sectionTitles(WidgetTester tester) => [
    for (final c in tester.widgetList<SectionCard>(find.byType(SectionCard)))
      c.title,
  ];

  bool nameFocused(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
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
    testWidgets('$label focuses Name (keyboard primed in the tap), '
        'defaults to Once with no Occurrences / Options; Repeats starts '
        'at every 1 week', (tester) async {
      final store = await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-events')), kind: kind);
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
          find.byKey(const ValueKey('panel-new-event')),
          kind: kind,
        );
      }
      // Primed synchronously, inside the tap.
      expect(page.primeSoftKeyboardCalls, primed + 1);
      await tester.pump();
      await tester.pump(nameRefocusDelay);
      await tester.pumpAndSettle();
      expect(nameFocused(tester), isTrue);
      // Once by default; just Details and Schedule.
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('editor-freq-once')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const ValueKey('editor-interval')), findsNothing);
      expect(sectionTitles(tester), ['Details', 'Schedule']);
      expect(find.text('Include in balance'), findsNothing);
      expect(find.text('Solve from a target total…'), findsNothing);
      // viaMenu: switch to Repeats, which starts at every 1 week.
      if (viaMenu) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('editor-freq-weekly')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('editor-freq-weekly')),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(_phrase(tester), 'Every week');
        // Still no Occurrences / Options for a new series.
        expect(sectionTitles(tester), ['Details', 'Schedule']);
      }
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
          matching: find.byType(TextField),
        ),
        '4.5',
      );
      await tester.tap(find.byKey(const ValueKey('editor-save')));
      await tester.pumpAndSettle();
      final created = store.txs.values.last;
      expect(created.enabled, isTrue);
      if (viaMenu) {
        expect(created.recurrenceMode, RecurrenceMode.every);
        expect(created.unit, RecurrenceUnit.weeks);
        expect(created.interval, 1);
        expect(created.endMode, EndMode.never);
      } else {
        expect(created.recurrenceMode, RecurrenceMode.once);
      }
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
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    final primed = page.primeSoftKeyboardCalls;
    await tester.tap(find.text('Rent'), kind: PointerDeviceKind.touch);
    await tester.pump();
    await tester.pump(nameRefocusDelay);
    await tester.pumpAndSettle();
    expect(page.primeSoftKeyboardCalls, primed);
    expect(nameFocused(tester), isFalse);
    expect(_phrase(tester), 'Every 3 months');
    expect(_intervalText(tester), '3');
    // Editing is just Details and Schedule too (no Occurrences / Options),
    // to the end of the form.
    final scroll = find
        .descendant(
          of: find.byType(EventEditor),
          matching: find.byType(Scrollable),
        )
        .first;
    // (Jumped, not dragged: a drag that lands on the month-day chips
    // paints them instead of scrolling.)
    final pos = tester.state<ScrollableState>(scroll).position;
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Include in balance'), findsNothing);
    pos.jumpTo(0);
    await tester.pumpAndSettle();
    expect(sectionTitles(tester), ['Details', 'Schedule']);
    await tester.pump(const Duration(seconds: 6));
  });

  bool amountFocused(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode
      .hasFocus;

  for (final (label, size) in const [
    ('phone', Size(390, 844)),
    ('desktop', Size(1440, 900)),
  ]) {
    testWidgets('$label: the editor is Amount (focused, number pad, Done), '
        'then type, then the category picker, then the schedule; no name '
        'field; Done saves', (tester) async {
      final store = await _pump(tester, size: size);
      final ctx = tester.element(find.byType(BalanceChart));
      unawaited(showEventEditor(ctx, streamId: 'p1'));
      await tester.pump();
      await tester.pump(nameRefocusDelay);
      await tester.pumpAndSettle();
      expect(amountFocused(tester), isTrue);
      expect(find.byKey(const ValueKey('editor-name')), findsNothing);
      final amount = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-amount')),
          matching: find.byType(EditableText),
        ),
      );
      expect(amount.keyboardType.decimal, isTrue);
      expect(amount.textInputAction, TextInputAction.done);
      // Order: Amount, type, category, schedule.
      final y = [
        for (final k in [
          'editor-amount',
          'editor-kind',
          'editor-category',
          'editor-freq-once',
        ])
          tester.getTopLeft(find.byKey(ValueKey(k))).dy,
      ];
      expect([...y]..sort(), y, reason: '$y');
      tester.testTextInput.enterText('4.5');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.calls.where((c) => c.startsWith('create')), hasLength(1));
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('other create paths (showEventEditor) focus Name too', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844));
    final ctx = tester.element(find.byType(BalanceChart));
    final primed = page.primeSoftKeyboardCalls;
    unawaited(showEventEditor(ctx, streamId: 'p1'));
    expect(page.primeSoftKeyboardCalls, primed + 1);
    await tester.pump();
    await tester.pump(nameRefocusDelay);
    await tester.pumpAndSettle();
    expect(nameFocused(tester), isTrue);
    expect(find.byKey(const ValueKey('editor-interval')), findsNothing);
    expect(sectionTitles(tester), ['Details', 'Schedule']);
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
      await tester.tap(find.byKey(const ValueKey('open-events')));
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
    await tester.tap(find.byKey(const ValueKey('open-events')));
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
      // 1 stream only: no stream toggles, just the Categories section
      // (Rent, Salary) and its Manage entry.
      expect(find.byType(CheckboxMenuButton), findsNWidgets(2));
      expect(find.byKey(const ValueKey('categories-heading')), findsOneWidget);
      expect(
        find.byKey(ValueKey('view-category-${fakeCategoryId('Rent')}')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('view-manage-categories')),
        findsOneWidget,
      );
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
      expect(find.text('No other streams'), findsNothing);
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

  // ── Header row: every action, More (⋮) last · the chart right under it ──

  for (final (size, wide, mid, desk, tiny) in const [
    (Size(320, 640), false, false, false, true),
    (Size(390, 844), false, false, false, false),
    (Size(800, 900), false, false, true, false),
    (Size(1000, 900), false, true, true, false),
    (Size(1440, 900), true, true, true, false),
  ]) {
    testWidgets('${size.width.toInt()}px header: every action in the top row, '
        'Reminders · Events (plain list) · View · More at the right '
        'end; the chart fills the body under it (no date range or tips '
        'rows)', (tester) async {
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
      // Right end, in order: Reminders · Events · View · More, at
      // every width (320 included: Events never hides in More).
      expect(inBar('fit-menu'), isTrue);
      expect(inBar('open-reminders'), isTrue);
      expect(r('timeline-more').left, greaterThan(r('fit-menu').right - 1));
      expect(r('timeline-more').left - r('fit-menu').right, lessThan(4));
      {
        expect(inBar('open-events'), isTrue);
        expect(
          r('open-events').left,
          greaterThan(r('open-reminders').right - 1),
        );
        expect(r('fit-menu').left - r('open-events').right, lessThan(4));
        expect(r('open-events').width, greaterThanOrEqualTo(40));
        expect(r('open-events').right, lessThanOrEqualTo(w));
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
          find.byKey(const ValueKey('open-events')),
        );
        expect(tx.style?.backgroundColor, isNull);
        expect(tx.style?.side, isNull);
        // Painted (ListGlyph), not an icon-font glyph a stale font lacks.
        expect(tx.icon, isA<ListGlyph>());
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('open-events')),
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
          tester.getSize(find.byKey(const ValueKey('open-events'))).height,
          greaterThanOrEqualTo(40),
        );
        expect(find.byTooltip('Events (2)'), findsOneWidget);
      }
      // Everything else (Today, Seed, Share, Stream settings) sits left of
      // Reminders.
      for (final k in [
        'go-today',
        'go-seed',
        'stream-share',
        'stream-settings',
      ]) {
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
        find.byKey(const ValueKey('stream-settings')),
        mid ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('stream-share')),
        mid ? findsOneWidget : findsNothing,
      );
      // No balance / alert summary in the header; the name is compact.
      for (final gone in ['header-today', 'header-lowest', 'header-runway']) {
        expect(find.byKey(ValueKey(gone)), findsNothing);
      }
      expect(find.textContaining('Seed \$'), findsNothing);
      // The stream picker stretches up to the actions (its arrow at the
      // right end; the empty space after the name opens it too).
      final name = r('header-stream-picker');
      expect(name.width, greaterThan(40));
      final firstAction = [
        for (final e
            in find
                .descendant(
                  of: find.byType(AppBar),
                  matching: find.byWidgetPredicate(
                    (w) => w is IconButton || w is ButtonStyleButton,
                  ),
                )
                .evaluate())
          tester.getRect(find.byWidget(e.widget)).left,
      ].where((l) => l >= name.right - 0.5).reduce(math.min);
      expect(firstAction - name.right, lessThanOrEqualTo(26));
      expect(find.byKey(const ValueKey('open-plan')), findsNothing);
      // No date range / heat map row and no tips row: the chart takes the
      // whole body, from just under the header to just above the bottom.
      for (final gone in [
        'jump-to-date',
        'range-heatmap',
        'range-start',
        'range-end',
        'tips-bar',
      ]) {
        expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
      }
      expect(find.textContaining('for actions'), findsNothing);
      expect(find.textContaining('to zoom'), findsNothing);
      final chart = tester.getRect(find.byType(BalanceChart));
      expect(chart.top - bar.bottom, inInclusiveRange(0, 14));
      expect(size.height - chart.bottom, inInclusiveRange(0, 14));
      expect(chart.left, lessThanOrEqualTo(17));
      expect(chart.width, greaterThan(w - 34));
      // What overflowed is in More (Stream settings first when it is there).
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(find.text('Stream settings'), mid ? findsNothing : findsOneWidget);
      expect(find.text('Share stream'), mid ? findsNothing : findsOneWidget);
      expect(find.text('Import events'), findsOneWidget);
      expect(find.text('Gestures & shortcuts'), findsOneWidget);
      // Events is never duplicated in More.
      expect(find.byKey(const ValueKey('more-events')), findsNothing);
      expect(find.text('Events (2)'), findsNothing);
      expect(find.text('Plan a payment'), findsNothing);
      if (tiny) {
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('open-events')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('panel-new-event')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  // Regression: after 1e4bdcc Events hid in More below 360px, which
  // is what zoomed / large-display-size phones report (e.g. 390 at 115%
  // page zoom ≈ 339). It must stay in the header at every phone width.
  for (final w in const [320.0, 339.0, 359.0, 360.0, 375.0, 412.0, 430.0]) {
    testWidgets('${w.toInt()}px phone: the Events list icon is in the '
        'header between Reminders and View, the name keeps room', (
      tester,
    ) async {
      await _pump(tester, size: Size(w, 800));
      expect(tester.takeException(), isNull);
      Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
      final tx = r('open-events');
      expect(tx.left, greaterThan(r('open-reminders').right - 1));
      expect(tx.right, lessThanOrEqualTo(r('fit-menu').left + 0.5));
      expect(tx.width, greaterThanOrEqualTo(40));
      expect(r('timeline-more').right, lessThanOrEqualTo(w));
      expect(r('header-stream-picker').width, greaterThan(40));
      expect(r('header-stream-picker').right, lessThanOrEqualTo(tx.left));
      // One sync dot: on the logo below 360, in the action row otherwise.
      expect(find.byType(RealtimeDot), findsOneWidget);
      expect(
        find.byKey(const ValueKey('brand-rt-dot')),
        w < 360 ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('panel-new-event')), findsOneWidget);
    });
  }

  // "New event today" (the day popup's +): always in the header, immediately
  // before Reminders, at every width; never in More.
  for (final w in const [
    320.0,
    339.0,
    360.0,
    390.0,
    402.0,
    412.0,
    600.0,
    959.0,
    960.0,
    1240.0,
    1440.0,
  ]) {
    testWidgets('${w.toInt()}px: New event today sits right before '
        'Reminders; the stream name keeps room', (tester) async {
      await _pump(tester, size: Size(w, w < 600 ? 800 : 900));
      expect(tester.takeException(), isNull);
      final btn = find.byKey(const ValueKey('new-event-today'));
      expect(btn, findsOneWidget);
      // The day popup's "+": same icon, same tonal circle.
      final nb = tester.widget<IconButton>(btn);
      expect(identical(nb.icon, dayAddIcon), isTrue);
      expect((nb.icon as Icon).icon, Icons.add_rounded);
      expect((nb.icon as Icon).size, 22);
      final want = dayAddButtonStyle();
      expect(
        nb.style!.backgroundColor!.resolve({}),
        want.backgroundColor!.resolve({}),
      );
      expect(
        nb.style!.foregroundColor!.resolve({}),
        want.foregroundColor!.resolve({}),
      );
      expect(nb.style!.visualDensity, VisualDensity.compact);
      expect(tester.widget<IconButton>(btn).tooltip, 'New event today');
      Rect r(String key) => tester.getRect(find.byKey(ValueKey(key)));
      final n = tester.getRect(btn), rem = r('open-reminders');
      expect(n.width, greaterThanOrEqualTo(36));
      expect(n.right, lessThanOrEqualTo(rem.left + 0.5));
      expect(rem.left - n.right, lessThan(12), reason: 'adjacent');
      expect((n.center.dy - rem.center.dy).abs(), lessThan(2));
      expect(n.left, greaterThan(r('header-stream-picker').right - 1));
      expect(r('header-stream-picker').width, greaterThan(40));
      expect(r('timeline-more').right, lessThanOrEqualTo(w));
      // Nothing else sits between it and Reminders.
      final between = find.byWidgetPredicate((wd) {
        if (wd is! IconButton && wd is! ButtonStyleButton) return false;
        final e = find.byWidget(wd);
        if (e.evaluate().isEmpty) return false;
        final b = tester.getRect(e.first);
        return b.left >= n.right - 0.5 &&
            b.right <= rem.left + 0.5 &&
            (b.center.dy - n.center.dy).abs() < 20;
      });
      expect(between, findsNothing);
      // Never duplicated in More.
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(find.text('New event today'), findsNothing);
    });
  }

  for (final w in const [402.0, 1440.0]) {
    testWidgets('${w.toInt()}px: New event today opens the New event '
        'editor on today; nothing is created until saved', (tester) async {
      final store = await _pump(tester, size: Size(w, 874));
      await tester.tap(find.byKey(const ValueKey('new-event-today')));
      await tester.pumpAndSettle();
      final editor = tester.widget<EventEditor>(find.byType(EventEditor));
      final now = DateTime.now();
      expect(editor.initialDate, DateTime(now.year, now.month, now.day));
      expect(editor.existing, isNull);
      expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('view-only stream: New event today stays visible, disabled', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(402, 874),
      setup: (s) => s.role = Role.viewer,
    );
    final btn = find.byKey(const ValueKey('new-event-today'));
    expect(btn, findsOneWidget);
    expect(tester.widget<IconButton>(btn).onPressed, isNull);
  });

  group('Events list hover highlights the event lane (desktop mouse)', () {
    final painted = <(String, Color, bool)>[];
    setUp(() {
      painted.clear();
      debugLanePaint = (id, c, e) => painted.add((id, c, e));
    });
    tearDown(() => debugLanePaint = null);

    String? highlighted(WidgetTester tester) => tester
        .widget<BalanceChart>(find.byType(BalanceChart))
        .highlightEvent
        ?.value;
    // A point on the row, clear of its buttons (left of the eye).
    Offset onRow(WidgetTester tester, String id) =>
        tester.getCenter(find.byKey(ValueKey('row-eye-$id'))) -
        const Offset(160, 0);
    Iterable<(String, Color, bool)> last(String id) =>
        painted.reversed.where((p) => p.$1 == id).take(1);

    testWidgets('hover sets the id, the painter emphasises its lane and '
        'dims the others; leaving clears it at once', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      expect(highlighted(tester), isNull);
      expect(painted.any((p) => p.$3), isFalse);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1430, 890));
      addTearDown(mouse.removePointer);
      await tester.pump();
      final view0 = tester.widget<BalanceChart>(find.byType(BalanceChart));
      painted.clear();
      await mouse.moveTo(onRow(tester, 'rent'));
      await tester.pump();
      expect(highlighted(tester), 'rent');
      expect(last('rent').single.$3, isTrue);
      expect(last('rent').single.$2.a, closeTo(1, 0.01));
      expect(last('salary').single.$3, isFalse);
      expect(last('salary').single.$2.a, lessThan(0.5));
      // Paint only: the view is untouched.
      final view1 = tester.widget<BalanceChart>(find.byType(BalanceChart));
      expect(view1.viewStart, view0.viewStart);
      expect(view1.visibleDays, view0.visibleDays);
      // Straight onto the next row: it takes over.
      await mouse.moveTo(onRow(tester, 'salary'));
      await tester.pump();
      expect(highlighted(tester), 'salary');
      expect(last('salary').single.$3, isTrue);
      expect(last('rent').single.$3, isFalse);
      // Off the list: cleared, every lane back to full colour.
      painted.clear();
      await mouse.moveTo(const Offset(1430, 890));
      await tester.pump();
      expect(highlighted(tester), isNull);
      expect(painted.any((p) => p.$3), isFalse);
      expect(last('rent').single.$2.a, closeTo(1, 0.01));
      expect(last('salary').single.$2.a, closeTo(1, 0.01));
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
    });

    testWidgets('a hidden event: no highlight; the eye paint-drag still '
        'works and never highlights', (tester) async {
      final store = await _pump(
        tester,
        setup: (s) => s.txs['rent'] = s.txs['rent']!.copyWith(enabled: false),
      );
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1430, 890));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(onRow(tester, 'rent'));
      await tester.pump();
      expect(highlighted(tester), isNull);
      expect(painted.any((p) => p.$3), isFalse);
      // Press the Salary eye and drag onto Rent's: paints, no highlight.
      await mouse.moveTo(const Offset(1430, 890));
      await tester.pump();
      store.calls.clear();
      await mouse.down(
        tester.getCenter(find.byKey(const ValueKey('row-eye-salary'))),
      );
      await tester.pump();
      expect(highlighted(tester), isNull);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('row-eye-rent'))),
      );
      await tester.pump();
      expect(highlighted(tester), isNull);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(store.calls, contains('enabled salary=false'));
      expect(highlighted(tester), isNull);
    });

    testWidgets('touch never highlights', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      final finger = await tester.startGesture(
        onRow(tester, 'rent'),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(highlighted(tester), isNull);
      await finger.cancel();
      await tester.pumpAndSettle();
      expect(highlighted(tester), isNull);
    });
  });

  testWidgets('More menu has no "Plan a payment"', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(find.text('Stream settings'), findsOneWidget);
    expect(find.text('Plan a payment'), findsNothing);
  });

  for (final size in const [Size(1440, 900), Size(320, 700)]) {
    // Desktop platforms use compact visual density (it shrinks a button's
    // minimum size): the menu still matches the split button.
    testWidgets('${size.width.toInt()}px: Events New ▾ menu matches the '
        'split button with desktop (compact) density', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await _pump(tester, size: size);
        final menu = find.byKey(const ValueKey('panel-new-menu'));
        await tester.tap(find.byKey(const ValueKey('open-events')));
        await tester.pumpAndSettle();
        final split = tester
            .getRect(find.byKey(const ValueKey('panel-new-event')))
            .expandToInclude(tester.getRect(menu));
        await tester.tap(menu);
        await tester.pumpAndSettle();
        final panel = tester.getRect(
          find
              .descendant(
                of: find
                    .byWidgetPredicate(
                      (w) => w.runtimeType.toString() == '_MenuPanel',
                    )
                    .last,
                matching: find.byType(Material),
              )
              .first,
        );
        expect(panel.left, closeTo(split.left, 0.5));
        expect(panel.width, closeTo(split.width, 0.5));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final size in const [Size(1440, 900), Size(390, 844), Size(320, 700)]) {
    testWidgets('${size.width.toInt()}px: Events New ▾ split button: '
        'New (default) and Plan', (tester) async {
      await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      // Main action: New opens the editor, as before.
      await tester.tap(find.byKey(const ValueKey('panel-new-event')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-back')));
      await tester.pumpAndSettle();
      // The menu: New and Plan.
      final menu = find.byKey(const ValueKey('panel-new-menu'));
      final main = tester.getRect(
        find.byKey(const ValueKey('panel-new-event')),
      );
      expect(tester.getRect(menu).left - main.right, lessThan(4));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('new-option-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('new-option-plan')), findsOneWidget);
      // The menu lines up under the whole split button: same left edge,
      // same width, inside the screen.
      // The visible surface (the panel's Material), not its constraints.
      final panel = tester.getRect(
        find
            .descendant(
              of: find
                  .byWidgetPredicate(
                    (w) => w.runtimeType.toString() == '_MenuPanel',
                  )
                  .last,
              matching: find.byType(Material),
            )
            .first,
      );
      final split = main.expandToInclude(tester.getRect(menu));
      expect(panel.left, closeTo(split.left, 0.5));
      expect(panel.width, closeTo(split.width, 0.5));
      expect(panel.top, greaterThanOrEqualTo(split.bottom));
      expect(panel.right, lessThanOrEqualTo(size.width));
      final item = tester.getRect(find.byKey(const ValueKey('new-option-new')));
      expect(item.left, greaterThanOrEqualTo(panel.left - 0.5));
      expect(item.right, lessThanOrEqualTo(panel.right + 0.5));
      await tester.tap(find.byKey(const ValueKey('new-option-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-back')));
      await tester.pumpAndSettle();
      expect(find.byType(PlanPanel), findsNothing);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-option-plan')));
      await tester.pumpAndSettle();
      // The panel closes and the planner opens.
      expect(find.byKey(const ValueKey('panel-new-event')), findsNothing);
      expect(find.byType(PlanPanel), findsOneWidget);
      expect(
        tester.widget<PlanPanel>(find.byType(PlanPanel)).tab,
        PlanTab.payment,
      );
      // The one Plan view, in "Spread a total".
      final modes = tester.widget<SegmentedButton<PlanTab>>(
        find.byKey(const ValueKey('plan-tabs')),
      );
      expect(modes.selected, {PlanTab.payment});
      expect(find.text('Reach a balance'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Total amount'), findsOneWidget);
      expect(find.text('Target balance (optional)'), findsNothing);
      if (size.width < 600) {
        // Full screen on a phone: one title for both modes.
        expect(find.widgetWithText(AppBar, 'Plan'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('chart selection Plan… opens Reach a balance (the largest '
      'one-off above the alert line); Set target sets its target; neither '
      'is in Spread a total', (tester) async {
    final store = await _pump(tester);
    BalanceChart chart() =>
        tester.widget<BalanceChart>(find.byType(BalanceChart));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.add(const Duration(days: 5));
    final end = today.add(const Duration(days: 20));
    chart().onPlanPeriod!(
      PeriodSummary(
        start: start,
        end: end,
        startBalance: 1234,
        endBalance: 1500,
        gains: 300,
        losses: 34,
        occurrences: const [],
      ),
    );
    await tester.pumpAndSettle();
    final panel = tester.widget<PlanPanel>(find.byType(PlanPanel));
    expect(panel.tab, PlanTab.goal);
    expect(
      tester
          .widget<SegmentedButton<PlanTab>>(
            find.byKey(const ValueKey('plan-tabs')),
          )
          .selected,
      {PlanTab.goal},
    );
    final req = store.goals.last;
    expect(req.solveFor, GoalVar.oneOff);
    expect(req.mode, GoalMode.floor);
    expect(req.startDate, start);
    expect(req.endDate, end);
    expect(req.startBalance, 1234);
    expect(req.targetBalance, 0);

    // Set target (only in Reach a balance): a chart tap sets the target.
    expect(find.byKey(const ValueKey('target-tool')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('target-tool')));
    await tester.pumpAndSettle();
    expect(chart().targetMode, isTrue);
    final day = today.add(const Duration(days: 40));
    chart().onTargetChanged!(day, 2345);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(store.goals.last.endDate, day);
    expect(store.goals.last.targetBalance, 2350);
    expect(tester.widget<PlanPanel>(find.byType(PlanPanel)).tab, PlanTab.goal);

    // Spread a total: the schedule follows; no target tool.
    await tester.tap(find.text('Spread a total'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('target-tool')), findsNothing);
    expect(store.solves.last.startDate, start);
    expect(store.solves.last.endDate, day);
    expect(store.solves.last.targetBalance, isNull);
    expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
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
  final seed = _stream().seedDate;
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
    testWidgets('toolbar at ${size.width.toInt()}px: no step buttons, no '
        'date range row, fits; logo left of the stream name', (tester) async {
      await _pump(tester, size: size);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shift-left')), findsNothing);
      expect(find.byKey(const ValueKey('shift-right')), findsNothing);
      expect(find.byKey(const ValueKey('jump-to-date')), findsNothing);
      // Budgie icon: left side of the header, after back, before the name.
      final logo = tester.getRect(find.byKey(const ValueKey('timeline-brand')));
      final back = tester.getRect(find.byKey(const ValueKey('timeline-back')));
      final name = tester.getRect(
        find.byKey(const ValueKey('header-stream-picker')),
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

  testWidgets('desktop: Today, Seed and View › Go to date… put the day at '
      'the left edge', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('go-seed')));
    await tester.pumpAndSettle();
    expectAtLeft(tester, seedDay, 'seed');
    await tester.tap(find.byKey(const ValueKey('go-today')));
    await tester.pumpAndSettle();
    expectAtLeft(tester, _day, 'today');
    // Go to date…: opens on the first visible day (today, the first day
    // clear of the left strip); pick the 15th.
    expect(_rangeStart(tester), DateFormat('d MMM').format(_day));
    final initial = _day;
    await tester.tap(find.byKey(const ValueKey('fit-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view-go-to-date')));
    await tester.pumpAndSettle();
    expect(find.text('Go to date'), findsOneWidget);
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expectAtLeft(tester, DateTime(initial.year, initial.month, 15), 'picked');
    // …and the view starts on it.
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

  group('Today / Seed select that day (as a date-lane tap)', () {
    final pickDate = find.byKey(const ValueKey('pick-date'));
    final bubble = find.byKey(const ValueKey('pick-bubble'));

    /// The bubble shows [day], with its +, and its line is on [day]'s
    /// start, on screen; the More menu's Import counts from it.
    Future<void> expectSelected(
      WidgetTester tester,
      DateTime day,
      String why,
    ) async {
      expect(bubble, findsOneWidget, reason: why);
      expect(find.byKey(const ValueKey('pick-add')), findsOneWidget);
      expect(
        tester.widget<Text>(pickDate).data,
        DateFormat('EEE d MMM y').format(day),
        reason: why,
      );
      final chart = tester.getRect(find.byType(BalanceChart));
      final line = tester.getRect(find.byKey(const ValueKey('pick-line')));
      expect(line.center.dx - chart.left, closeTo(xOfDay(tester, day), 1.5));
      expect(line.left, greaterThanOrEqualTo(chart.left), reason: why);
      expect(line.right, lessThanOrEqualTo(chart.right), reason: why);
      final b = tester.getRect(bubble);
      expect(b.left, greaterThanOrEqualTo(chart.left), reason: why);
      expect(b.right, lessThanOrEqualTo(chart.right), reason: why);
      expect(b.top, greaterThanOrEqualTo(chart.top), reason: why);
      expect(b.bottom, lessThanOrEqualTo(chart.bottom), reason: why);
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.byKey(const ValueKey('more-import')),
            )
            .enabled,
        isTrue,
        reason: why,
      );
      expect(
        find.text('Dates count from ${DateFormat('EEE d MMM y').format(day)}'),
        findsOneWidget,
        reason: why,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    testWidgets('desktop header buttons: selected, then dismissed like a '
        'tap (Esc, a tap elsewhere, moving the view)', (tester) async {
      final store = await _pump(tester);
      expect(bubble, findsNothing);
      await tester.tap(find.byKey(const ValueKey('go-seed')));
      await tester.pumpAndSettle();
      expectAtLeft(tester, seedDay, 'seed');
      await expectSelected(tester, seedDay, 'seed');
      // Today moves the selection to today.
      await tester.tap(find.byKey(const ValueKey('go-today')));
      await tester.pumpAndSettle();
      expectAtLeft(tester, _day, 'today');
      await expectSelected(tester, _day, 'today');
      // It stays up (no timeout) …
      await tester.pump(const Duration(seconds: 5));
      expect(bubble, findsOneWidget);
      // … until a tap elsewhere …
      final chart = tester.getRect(find.byType(BalanceChart));
      await tester.tapAt(chart.center + const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(bubble, findsNothing, reason: 'a tap elsewhere dismisses');
      await tester.tap(find.byKey(const ValueKey('go-today')));
      await tester.pumpAndSettle();
      expect(bubble, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('go-seed')));
      await tester.pumpAndSettle();
      expect(bubble, findsOneWidget);
      // … or the view moving (a pan).
      await tester.dragFrom(
        chart.center + const Offset(0, -150),
        const Offset(-120, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(bubble, findsNothing, reason: 'moving the view dismisses');
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.byKey(const ValueKey('more-import')),
            )
            .enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // Never creates, trims or edits anything.
      expect(
        store.calls.where(
          (c) =>
              RegExp(r'^(create|update|override|delete|skip|import)')
                  .hasMatch(c),
        ),
        isEmpty,
      );
    });

    testWidgets('desktop: Esc dismisses a Today selection', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('go-today')));
      await tester.pumpAndSettle();
      expect(bubble, findsOneWidget);
      // Straight after the button (no press on the chart): the chart took
      // focus, so Esc reaches it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(bubble, findsNothing);
    });

    for (final size in const [Size(390, 844), Size(402, 874)]) {
      testWidgets('phone ${size.width.toInt()}: View menu Go to seed / today '
          'select the day', (tester) async {
        final store = await _pump(tester, size: size);
        for (final (label, day) in [
          ('Go to seed date', seedDay),
          ('Go to today', _day),
        ]) {
          await tester.tap(find.byKey(const ValueKey('fit-menu')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expectAtLeft(tester, day, label);
          await expectSelected(tester, day, label);
        }
        // The + opens the editor on that day; nothing is created yet.
        await tester.tap(find.byKey(const ValueKey('pick-add')));
        await tester.pumpAndSettle();
        expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Today twice keeps the same selection', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('go-today')));
      await tester.pumpAndSettle();
      final first = tester.widget<Text>(pickDate).data;
      // Today again on the same day: same selection, still visible.
      await tester.tap(find.byKey(const ValueKey('go-today')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(pickDate).data, first);
    });
  });

  testWidgets('More menu (below 960px): Stream settings is the first item', (
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
    expect(y('Stream settings'), lessThan(y('Share stream')));
    expect(y('Share stream'), lessThan(y('Import events')));
    await tester.tap(find.text('Stream settings'));
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

  testWidgets('popup Trim From Here ends that row\'s series the day before '
      'the tapped occurrence; the 5s tip\'s Undo restores the end and '
      'once-offs', (tester) async {
    final far = _day.add(const Duration(days: 70));
    for (final (size, kind) in const [
      (Size(390, 844), PointerDeviceKind.touch),
      (Size(1440, 900), PointerDeviceKind.mouse),
    ]) {
      // Both start well before the view, so no shown day is a first
      // occurrence (that would delete).
      final early = _day.subtract(const Duration(days: 140));
      final store = await _pump(
        tester,
        size: size,
        setup: (s) {
          s.txs['rent'] = _withOverrides(
            s.txs['rent']!.copyWith(startDate: early),
            {
              far: OccurrenceOverride(
                direction: EventDirection.debit,
                amount: Decimal.fromInt(99),
              ),
            },
          );
          s.txs['salary'] = s.txs['salary']!.copyWith(startDate: early);
        },
      );
      final before = store.txs['rent']!;
      final dates = estimateOccurrenceDates(before, maxCount: 400);
      store.calls.clear();
      await revealDayTip(tester, kind);
      // Rent and Salary share each day: each row's ⋮ has its own Trim.
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
      expect(
        find.descendant(of: trimRent, matching: find.text('Trim From Here')),
        findsOneWidget,
      );
      expect(store.calls.where((c) => !c.startsWith('balance')), isEmpty);
      await tester.tap(trimRent, kind: kind);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing, reason: 'no ask');
      final rent = store.txs['rent']!;
      expect(rent.endMode, EndMode.untilDate);
      final end = rent.endDate!;
      final tapped = end.add(const Duration(days: 1));
      expect(dates, contains(tapped), reason: 'ends the day before the dot');
      final kept = estimateOccurrenceDates(rent, maxCount: 400);
      expect(kept, dates.where((d) => d.isBefore(tapped)).toList());
      expect(rent.overrides, isEmpty, reason: 'once-off past the end goes');
      expect(store.txs['salary']!.endMode, EndMode.never);
      expect(store.calls.where((c) => c.startsWith('create')), isEmpty);
      final tip = find.byKey(const ValueKey('undo-tip'));
      expect(tip, findsOneWidget);
      expect(
        find.descendant(
          of: tip,
          matching: find.textContaining('Trimmed “Rent” · ends '),
        ),
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

  testWidgets('popup Trim: none for viewers; from a series\' only '
      'occurrence it asks, then deletes (Undo brings it back)', (tester) async {
    await _pump(tester, setup: (s) => s.role = Role.viewer);
    await _revealTip(tester, PointerDeviceKind.mouse);
    expect(_keyStarts('tip-menu'), findsNothing);
    // Every day is Rent's only occurrence: trimming from it leaves nothing.
    final store = await _pump(
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
    await revealDayTip(tester, PointerDeviceKind.touch);
    Future<void> trimRent() async {
      await _openRowMenu(tester, 'rent', PointerDeviceKind.touch);
      expect(find.byKey(const ValueKey('tip-menu-edit-rent')), findsOneWidget);
      expect(find.byKey(const ValueKey('tip-menu-new-rent')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('tip-menu-trim-rent')),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Delete Rent?'), findsOneWidget);
    }

    await trimRent();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.txs['rent'], isNotNull, reason: 'Cancel keeps it');
    expect(store.calls.where((c) => c.startsWith('delete')), isEmpty);
    await revealDayTip(tester, PointerDeviceKind.touch);
    await trimRent();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.txs.containsKey('rent'), isFalse);
    expect(store.calls, contains('delete rent'));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(store.txs.values.map((t) => t.name), contains('Rent'));
    await tester.pump(const Duration(seconds: 6));
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
    testWidgets('${size.width.toInt()}px ${kind.name}: View › Go to date… '
        'opens on the first visible day and shows the picked day from the '
        'left, keeping the span', (tester) async {
      final store = await _pump(tester, size: size);
      store.calls.clear();
      BalanceChart chart() =>
          tester.widget<BalanceChart>(find.byType(BalanceChart));
      DateTime first() => _firstDay(tester);
      Future<void> goTo(DateTime day) async {
        await tester.tap(find.byKey(const ValueKey('fit-menu')), kind: kind);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('view-go-to-date')),
          kind: kind,
        );
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.text('Go to date'), findsOneWidget);
        await tester.tap(find.byTooltip('Switch to input'));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byType(TextField),
        );
        expect(
          tester.widget<TextField>(field).controller!.text,
          DateFormat('MM/dd/yyyy').format(first()),
          reason: 'opens on the first visible day',
        );
        await tester.enterText(field, DateFormat('MM/dd/yyyy').format(day));
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }

      final span = chart().visibleDays;
      for (final day in [_plus(first(), -40), _plus(first(), 75)]) {
        await goTo(day);
        expect(first(), day);
        expect(chart().visibleDays, closeTo(span, 1e-6));
      }
      // Cancel leaves the view alone.
      final before = chart().viewStart;
      await tester.tap(find.byKey(const ValueKey('fit-menu')), kind: kind);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('view-go-to-date')),
        kind: kind,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(chart().viewStart, before);
      expect(
        store.calls.where(
          (c) => c.startsWith('create') || c.startsWith('update'),
        ),
        isEmpty,
        reason: 'going to a date never creates or edits',
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, kind) in const [
    (Size(390, 844), PointerDeviceKind.touch),
    (Size(1440, 900), PointerDeviceKind.mouse),
  ]) {
    testWidgets('${size.width.toInt()}px ${kind.name}: tapping an event '
        'net chip shows the day\'s popup, its dot only its event; never '
        'creates', (tester) async {
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
      // The day's net chip lists the whole day; a dot never opens the
      // info popup (lanes reveal it; its click opens the action menu).
      expect(byLabel, containsAll(['Rent', 'Salary']));
      expect(byLabel.any((t) => t.startsWith('Net')), isTrue);
      expect(rectByLabel, isNotNull);
      await tester.tapAt(origin + dot!, kind: kind);
      await tester.pump();
      expect(tip, findsNothing);
      if (find.byKey(const ValueKey('dot-menu-new')).evaluate().isNotEmpty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      await settle();
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
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

  group('import needs a selected day', () {
    /// Taps up the date lane (bottom of the chart) until a day pins.
    Future<void> pinDay(WidgetTester tester) async {
      final r = tester.getRect(find.byType(BalanceChart));
      for (var y = r.bottom - 4; y > r.bottom - 80; y -= 4) {
        await tester.tapAt(
          Offset(r.center.dx, y),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 400));
        if (find.byKey(const ValueKey('pick-bubble')).evaluate().isNotEmpty) {
          await tester.pumpAndSettle();
          return;
        }
      }
      fail('a tap on the date lane should pin a day');
    }

    for (final size in const [Size(1440, 900), Size(402, 681)]) {
      testWidgets('${size.width.toInt()}px: blocked with a hint, then the '
          'pinned day is the root', (tester) async {
        final store = await _pump(tester, size: size);
        await tester.tap(find.byKey(const ValueKey('timeline-more')));
        await tester.pumpAndSettle();
        final item = tester.widget<PopupMenuItem<String>>(
          find.byKey(const ValueKey('more-import')),
        );
        expect(item.enabled, isFalse);
        expect(find.byKey(const ValueKey('more-import-hint')), findsOneWidget);
        expect(find.text(importNeedsDayHint), findsOneWidget);
        await tester.tap(find.text('Import events'), warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(find.text('Paste a JSON array'), findsNothing);
        expect(find.byKey(const ValueKey('import-paste')), findsNothing);
        expect(store.calls.where((c) => c.startsWith('import')), isEmpty);
        await tester.tapAt(const Offset(5, 400));
        await tester.pumpAndSettle();

        await pinDay(tester);
        final bubble = find.byKey(const ValueKey('pick-bubble'));
        final dateText = tester
            .widgetList<Text>(
              find.descendant(of: bubble, matching: find.byType(Text)),
            )
            .map((t) => t.data ?? '')
            .firstWhere((t) => RegExp(r'\d{4}$').hasMatch(t));
        final day = DateFormat('EEE d MMM y').parse(dateText);

        await tester.tap(find.byKey(const ValueKey('timeline-more')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.byKey(const ValueKey('more-import')),
              )
              .enabled,
          isTrue,
        );
        expect(find.text('Dates count from $dateText'), findsOneWidget);
        await tester.tap(find.text('Import events'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('import-paste')), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('import-root')))
              .textSpan!
              .toPlainText(),
          'Dates count from $dateText (the selected day).',
        );
        await _pasteImport(
          tester,
          '[{"name":"Bonus","direction":"credit","amount":5,'
          '"startOffset":0,"recurrence":{"mode":"once"}}]',
        );
        expect(
          store.calls,
          contains('import ${importRootParam(day)} dryRun=true'),
        );
        await tester.tap(find.text('Import 1'));
        await tester.pumpAndSettle();
        expect(
          store.calls,
          contains('import ${importRootParam(day)} dryRun=false'),
        );
        expect(find.textContaining('Imported 1 event'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    /// Pins a day and imports one item; returns the store.
    Future<_Store> importOne(WidgetTester tester, {Size? size}) async {
      final store = await _pump(tester, size: size ?? const Size(1440, 900));
      await pinDay(tester);
      Future<void> once() async {
        await tester.tap(find.byKey(const ValueKey('timeline-more')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Import events'));
        await tester.pumpAndSettle();
        await _pasteImport(
          tester,
          '[{"direction":"credit","amount":5,"startOffset":0,'
          '"recurrence":{"mode":"once"}}]',
        );
        await tester.tap(find.text('Import 1'));
        await tester.pumpAndSettle();
      }

      await once();
      return store;
    }

    final bar = find.byKey(const ValueKey('import-undo-bar'));

    for (final size in const [Size(1440, 900), Size(402, 681)]) {
      testWidgets('${size.width.toInt()}px: the undo bar stays (no timeout) '
          'and Undo removes exactly the imported ids', (tester) async {
        final store = await importOne(tester, size: size);
        expect(bar, findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('import-undo-message')))
              .data,
          'Imported 1 event',
        );
        // Far past the 5 s undo tip (and past 10 s): still up.
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pumpAndSettle();
        expect(bar, findsOneWidget);
        final created = store.calls.lastWhere(
          (c) => c.startsWith('import ') && c.endsWith('false'),
        );
        final id = 'imp-${store.calls.indexOf(created) + 1}';
        await tester.tap(find.byKey(const ValueKey('import-undo')));
        await tester.pumpAndSettle();
        expect(store.calls.where((c) => c.startsWith('undoImport')), [
          'undoImport $id',
        ]);
        expect(bar, findsNothing);
        expect(find.text('Import undone'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the close box dismisses the bar and keeps the import', (
      tester,
    ) async {
      final store = await importOne(tester);
      await tester.tap(find.byKey(const ValueKey('import-undo-close')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(store.calls.where((c) => c.startsWith('undoImport')), isEmpty);
      expect(find.text('Import undone'), findsNothing);
    });

    testWidgets('a failed undo keeps the bar with the error and Retry', (
      tester,
    ) async {
      final store = await importOne(tester);
      store.undoFails = true;
      await tester.tap(find.byKey(const ValueKey('import-undo')));
      await tester.pumpAndSettle();
      expect(bar, findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('import-undo-message')))
            .data,
        allOf(startsWith('Undo failed'), endsWith('Nothing was removed.')),
      );
      expect(find.text('Retry'), findsOneWidget);
      store.undoFails = false;
      await tester.tap(find.byKey(const ValueKey('import-undo')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(find.text('Import undone'), findsOneWidget);
      expect(
        store.calls.where((c) => c.startsWith('undoImport')),
        hasLength(2),
      );
    });

    testWidgets('dismissing the selected day blocks import again', (
      tester,
    ) async {
      await _pump(tester);
      await pinDay(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      if (find.byKey(const ValueKey('pick-bubble')).evaluate().isNotEmpty) {
        final r = tester.getRect(find.byType(BalanceChart));
        await tester.tapAt(Offset(r.center.dx, r.top + 30));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(const ValueKey('pick-bubble')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('timeline-more')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.byKey(const ValueKey('more-import')),
            )
            .enabled,
        isFalse,
      );
      expect(find.text(importNeedsDayHint), findsOneWidget);
    });
  });

  test('importRootParam keeps the calendar date across Sydney DST days', () {
    // DST starts Sun 4 Oct 2026 and ends Sun 5 Apr 2026 (local midnights).
    for (final d in [
      DateTime(2026, 10, 4),
      DateTime(2026, 10, 3, 23, 59),
      DateTime(2026, 4, 5),
      DateTime(2027, 4, 4),
      DateTime(2026, 12, 31),
      DateTime(2028, 2, 29),
      DateTime(2026, 1, 31),
    ]) {
      expect(
        importRootParam(d),
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}',
      );
    }
    expect(importRootParam(DateTime(2026, 10, 4)), '2026-10-04');
    expect(
      importRootParam(DateTime(2026, 10, 3).add(const Duration(days: 1))),
      '2026-10-04',
    );
    expect(
      importRootParam(DateTime(2026, 4, 4, 0).add(const Duration(days: 1))),
      '2026-04-05',
    );
  });

  group('hide an event (the eye / include flag)', () {
    for (final (size, kind) in const [
      (Size(1440, 900), PointerDeviceKind.mouse),
      (Size(390, 844), PointerDeviceKind.touch),
    ]) {
      testWidgets('${kind.name}: Hide (eye-off) in a lane\'s menu hides the '
          'series at once and excludes it (saved on the server, balance '
          'refetched); Hid "Rent" offers Undo; the list\'s eye shows it', (
        tester,
      ) async {
        final placed = <(String?, Offset)>[];
        final names = <String>[];
        debugLaneDot = (id, c) => placed.add((id, c));
        debugLaneName = (name, _) => names.add(name);
        addTearDown(() {
          debugLaneDot = null;
          debugLaneName = null;
        });
        final store = await _pump(tester, size: size, setup: _singles);
        store.calls.clear();
        expect(names, contains('Rent'));
        final chart = tester.getRect(find.byType(BalanceChart));
        final dot = placed
            .where(
              (p) =>
                  p.$1 == 'rent' &&
                  p.$2.dx > chart.width * 0.3 &&
                  p.$2.dx < chart.width * 0.8,
            )
            .first
            .$2;
        await tester.tapAt(
          chart.topLeft + dot + const Offset(4, 0),
          kind: kind,
        );
        await tester.pumpAndSettle();
        final hide = find.byKey(const ValueKey('dot-menu-hide'));
        expect(find.text('Hide Series'), findsOneWidget);
        expect(
          find.descendant(of: hide, matching: find.byIcon(eventShownIcon)),
          findsOneWidget,
        );
        await tester.tap(hide, kind: kind);
        await tester.pumpAndSettle();
        expect(store.calls, contains('enabled rent=false'));
        expect(store.calls, contains('balance'), reason: 'balance refetched');
        expect(store.txs['rent']!.enabled, isFalse);
        expect(find.text('Hid "Rent"'), findsOneWidget);
        names.clear();
        placed.clear();
        tester
            .renderObjectList(find.byType(CustomPaint))
            .forEach((r) => r.markNeedsPaint());
        await tester.pump();
        expect(names, isNot(contains('Rent')));
        expect(names, contains('Salary'));
        expect(placed.map((p) => p.$1), isNot(contains('rent')));
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(store.calls, contains('enabled rent=true'));
        expect(store.txs['rent']!.enabled, isTrue);
        await tester.pump(const Duration(seconds: 6));
        // Hidden again from the list's eye; shown again from it too.
        await tester.tap(find.byKey(const ValueKey('open-events')));
        await tester.pumpAndSettle();
        final eye = find.byKey(const ValueKey('row-eye-rent'));
        expect(
          find.descendant(of: eye, matching: find.byIcon(eventShownIcon)),
          findsOneWidget,
        );
        expect(find.byType(Checkbox), findsNothing);
        await tester.tap(eye, kind: kind);
        await tester.pumpAndSettle();
        expect(store.txs['rent']!.enabled, isFalse);
        expect(
          find.descendant(of: eye, matching: find.byIcon(eventHiddenIcon)),
          findsOneWidget,
        );
        expect(
          tester
              .widget<BalanceChart>(
                find.byType(BalanceChart, skipOffstage: false),
              )
              .events['rent']!
              .enabled,
          isFalse,
          reason: 'the timeline gets the same flag',
        );
        await tester.tap(eye, kind: kind);
        await tester.pumpAndSettle();
        expect(store.txs['rent']!.enabled, isTrue);
      });
    }

    testWidgets('viewers get no Hide (it saves to the server)', (tester) async {
      await _pump(tester, setup: (s) => s.role = Role.viewer);
      final chart = tester.widget<BalanceChart>(find.byType(BalanceChart));
      expect(chart.onHideEvent, isNull);
    });
  });
}

/// The first day clear of the left strip (what Go to date… opens on).
DateTime _firstDay(WidgetTester tester) {
  final c = tester.widget<BalanceChart>(find.byType(BalanceChart));
  final w = tester.getSize(find.byType(BalanceChart)).width;
  final inset = ChartLayout.laneNameWidth(w) * c.visibleDays / w;
  return dateFromDayCoord(
    (dayCoord(c.viewStart) + inset - 1e-6).ceilToDouble(),
  );
}

/// [_firstDay] as "9 Oct".
String _rangeStart(WidgetTester tester) =>
    DateFormat('d MMM').format(_firstDay(tester));

DateTime _plus(DateTime x, int days) => DateTime(x.year, x.month, x.day + days);

void _three(_Store s) {
  final r = s.txs['rent']!;
  s.txs['gym'] = BudgetEvent(
    id: 'gym',
    streamId: r.streamId,
    name: 'Gym',
    direction: EventDirection.debit,
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
      // A day popup: three rows plus its net footer.
      (3, _three, touch ? 180.0 : 135.0),
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

/// Puts [json] on the (mock) clipboard and taps the import dialog's Paste.
Future<void> _pasteImport(WidgetTester tester, String json) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? {'text': json} : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('import-paste')));
  await tester.pumpAndSettle();
}

/// The editor's live frequency phrase.
String _phrase(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('editor-freq-phrase'))).data!;

String _intervalText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('editor-interval')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;
