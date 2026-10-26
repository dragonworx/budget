// Per-event colour: model round trip, the lane / palette helpers, the
// editor's coloured header and its palette picker, and the day pick's ✂
// ("End all events on this day": one confirm, one batch, one Undo).
import 'dart:math' as math;

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/features/timeline/trim.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      child: const MaterialApp(home: TimelinePage(streamId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

Color _headerColor(WidgetTester tester) => tester
    .widget<AnimatedContainer>(find.byKey(const ValueKey('editor-header')))
    .decoration
    .let((d) => (d! as BoxDecoration).color!);

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

Future<void> _openPick(WidgetTester tester, PointerDeviceKind kind) async {
  final chart = tester.getRect(find.byType(BalanceChart));
  await tester.tapAt(Offset(chart.center.dx, chart.bottom - 8), kind: kind);
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('pick-bubble')), findsOneWidget);
}

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

void main() {
  tearDown(() => eventColorRandom = null);

  test('colour round trip: fromJson (and the colour alias), toJson, '
      'create / patch body always carries it, copyWith clears', () {
    final t = BudgetEvent.fromJson({
      'id': 'x',
      'streamId': 'a',
      'name': 'n',
      'direction': 'debit',
      'amount': '1',
      'startDate': '2026-10-01',
      'recurrenceMode': 'once',
      'color': '#3c8a6e',
    });
    expect(t.color, '#3C8A6E');
    expect(t.toJson()['color'], '#3C8A6E');
    expect(t.toCreateJson()['color'], '#3C8A6E');
    final alias = BudgetEvent.fromJson({...t.toJson(), 'color': null}).let(
      (_) => BudgetEvent.fromJson({
        'id': 'y',
        'stream_id': 'a',
        'direction': 'credit',
        'amount': '1',
        'start_date': '2026-10-01',
        'recurrence_mode': 'once',
        'colour': '9250c8',
      }),
    );
    expect(alias.color, '#9250C8');
    final cleared = t.copyWith(clearColor: true);
    expect(cleared.color, isNull);
    expect(
      cleared.toCreateJson().containsKey('color'),
      isTrue,
      reason: 'null is sent: back to the positional colour',
    );
    expect(cleared.toCreateJson()['color'], isNull);
    expect(normalizeEventColor('red'), isNull);
  });

  test('lanes: own colour, else positional; hex helpers; new colours '
      'prefer ones no lane wears', () {
    final lanes = buildLaneSet(
      order: ['a', 'b', 'c'],
      events: {
        'a': _ev('a', 'A'),
        'b': _ev('b', 'B', color: '#B8488E'),
        'c': _ev('c', 'C'),
      },
    );
    expect(
      [for (final l in lanes.lanes) l.color],
      [laneColor(0), const Color(0xFFB8488E), laneColor(2)],
    );
    expect(colorToHex(laneColors[3]), '#2B8AA8');
    expect(colorFromHex('#2b8aa8'), laneColors[3]);
    expect(laneColorIndexOf(laneColors[7]), 7);
    expect(laneColorIndexOf(const Color(0xFF123456)), isNull);
    expect(laneColorNames, hasLength(laneColors.length));
    expect(
      laneColorFor(
        'c',
        order: ['a', 'b', 'c'],
        events: {'a': _ev('a', 'A'), 'b': _ev('b', 'B'), 'c': _ev('c', 'C')},
      ),
      laneColor(2),
    );
    // Used: blue (a), magenta (b), amber (c): never picked while others
    // are free.
    final used = {laneColors[0], laneColors[4], laneColors[2]};
    for (var seed = 0; seed < 200; seed++) {
      final c = pickNewEventColor(lanes, math.Random(seed));
      expect(laneColors, contains(c));
      expect(used, isNot(contains(c)), reason: 'seed $seed');
    }
    // All 12 taken: any of the least used.
    final full = buildLaneSet(
      order: [for (var i = 0; i < 13; i++) '$i'],
      events: {for (var i = 0; i < 13; i++) '$i': _ev('$i', '$i')},
    );
    for (var seed = 0; seed < 50; seed++) {
      expect(
        pickNewEventColor(full, math.Random(seed)),
        isNot(laneColors[0]),
        reason: 'blue is used twice',
      );
    }
  });

  test('the editor header text (and the picker\'s check) reads on every '
      'palette colour', () {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    for (final c in laneColors) {
      final text = Color.alphaBlend(laneTextColor, c);
      // Large (title) text: ≥3:1 (AA); the small caps label has a shadow.
      expect(ratio(text, c), greaterThanOrEqualTo(3.5), reason: '$c');
    }
  });

  testWidgets('New: the header wears a random palette colour no lane has; '
      'the picker recolours it live and Save stores it', (tester) async {
    eventColorRandom = math.Random(7);
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-new-event')));
    await tester.pumpAndSettle();
    final first = _headerColor(tester);
    expect(laneColors, contains(first));
    expect(first, isNot(laneColor(0)), reason: 'Rent wears blue');
    expect(first, isNot(const Color(0xFF3C8A6E)), reason: 'Gym wears pine');
    // Open the picker: 12 swatches, the current one ticked.
    await tester.tap(find.byKey(const ValueKey('editor-color')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-color-grid')), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      expect(find.byKey(ValueKey('color-swatch-$i')), findsOneWidget);
    }
    final sel = laneColorIndexOf(first)!;
    expect(
      find.descendant(
        of: find.byKey(ValueKey('color-swatch-$sel')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-color-grid')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    final pick = (sel + 5) % 12;
    await tester.tap(find.byKey(ValueKey('color-swatch-$pick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-color-grid')), findsNothing);
    expect(_headerColor(tester), laneColors[pick], reason: 'live');
    await tester.enterText(_field('editor-name'), 'Cafe');
    await tester.enterText(_field('editor-amount'), '12');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.created.single.color, colorToHex(laneColors[pick]));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Edit: the header starts on the lane\'s colour (own or '
      'positional); unchanged it saves what was stored, a pick saves the '
      'pick; keyboard opens the picker', (tester) async {
    final store = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    // Rent: no colour of its own, first lane → blue.
    await tester.tap(find.text('Rent'));
    await tester.pumpAndSettle();
    expect(_headerColor(tester), laneColor(0));
    await tester.enterText(_field('editor-amount'), '60');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(
      store.updated.last.color,
      isNull,
      reason: 'not picked: stays on the positional palette',
    );
    await tester.pump(const Duration(seconds: 6));

    // Gym: its own pine.
    await tester.tap(find.text('Gym'));
    await tester.pumpAndSettle();
    expect(_headerColor(tester), const Color(0xFF3C8A6E));
    // Keyboard: focus the swatch button, Enter opens, Enter picks.
    final button = find.byKey(const ValueKey('editor-color'));
    Focus.of(
      tester.element(
        find.descendant(of: button, matching: find.byType(Icon)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-color-grid')), findsOneWidget);
    // The selected swatch (pine, 8) has focus; Tab to the next (plum).
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_headerColor(tester), laneColors[9]);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.updated.last.id, 'gym');
    expect(store.updated.last.color, '#8E5A9E');
    await tester.pump(const Duration(seconds: 6));
  });

  for (final (size, kind) in [
    (const Size(412, 915), PointerDeviceKind.touch),
    (const Size(1440, 900), PointerDeviceKind.mouse),
  ]) {
    testWidgets('${size.width.toInt()}px: the day pick\'s ✂ sits next to '
        '"+", confirms once, ends / deletes in one batch, one Undo', (
      tester,
    ) async {
      final store = await _pump(
        tester,
        size: size,
        setup: (s) {
          // Starts well after any day in view: deleted.
          s.txs['later'] = _ev(
            'later',
            'Holiday',
            mode: RecurrenceMode.once,
            start: _day.add(const Duration(days: 400)),
          );
          // Already over: untouched.
          s.txs['done'] = _ev(
            'done',
            'Old loan',
            end: EndMode.untilDate,
            endDate: _day.subtract(const Duration(days: 7)),
          );
        },
      );
      await _openPick(tester, kind);
      final trim = find.byKey(const ValueKey('pick-trim'));
      final add = find.byKey(const ValueKey('pick-add'));
      expect(trim, findsOneWidget);
      expect(
        find.descendant(of: trim, matching: find.byType(Text)),
        findsNothing,
        reason: 'icon only',
      );
      expect(
        find.descendant(
          of: trim,
          matching: find.byIcon(Icons.content_cut_rounded),
        ),
        findsOneWidget,
      );
      // Right next to "+", on its left, same row.
      final tr = tester.getRect(trim), ar = tester.getRect(add);
      expect(ar.left - tr.right, inInclusiveRange(0, 12));
      expect(tr.center.dy, closeTo(ar.center.dy, 1));
      final label = tester
          .widget<Text>(find.byKey(const ValueKey('pick-date')))
          .data!;

      await tester.tap(trim, kind: kind);
      await tester.pumpAndSettle();
      expect(find.text('End all events on $label?'), findsOneWidget);
      expect(find.textContaining('Rent, Gym'), findsOneWidget);
      expect(find.textContaining('Holiday'), findsOneWidget);
      expect(find.textContaining('Old loan'), findsNothing);
      // Cancel: nothing happens.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.calls, isEmpty);

      await tester.tap(trim, kind: kind);
      await tester.pumpAndSettle();
      await tester.tap(find.text('End all'));
      await tester.pumpAndSettle();
      expect(store.calls, hasLength(1), reason: 'one batch request');
      expect(store.calls.single, startsWith('endAllOn '));
      expect(store.calls.single, endsWith('rent,gym,later'));
      expect(store.txs['rent']!.endMode, EndMode.untilDate);
      expect(store.txs.containsKey('later'), isFalse);
      expect(
        store.txs['done']!.endDate,
        _day.subtract(const Duration(days: 7)),
      );
      final tip = find.byKey(const ValueKey('undo-tip'));
      expect(tip, findsOneWidget);
      expect(
        find.textContaining('Ended 2 series, deleted 1 event'),
        findsOneWidget,
      );
      // Nothing left to end that day: the ✂ is disabled, saying so.
      final btn = tester.widget<IconButton>(trim);
      expect(btn.onPressed, isNull);
      expect(btn.tooltip, startsWith('Nothing runs past'));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(store.calls.last, 'undo batch-1');
      expect(store.txs['rent']!.endMode, EndMode.never);
      expect(store.txs.containsKey('later'), isTrue);
      expect(tester.widget<IconButton>(trim).onPressed, isNotNull);
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('viewers: the ✂ is there but disabled', (tester) async {
    final store = await _pump(tester, setup: (s) => s.role = Role.viewer);
    await _openPick(tester, PointerDeviceKind.mouse);
    final btn = tester.widget<IconButton>(
      find.byKey(const ValueKey('pick-trim')),
    );
    expect(btn.onPressed, isNull);
    expect(btn.tooltip, startsWith('View only'));
    expect(store.calls, isEmpty);
  });

  test('endOnDay: series running past the day end on it; events starting '
      'after it go; the rest stay', () {
    final d = _day;
    expect(endOnDay(_ev('a', 'a'), d), DayTrim.end);
    expect(
      endOnDay(_ev('a', 'a', start: d), d),
      DayTrim.end,
      reason: 'starts on the day: keeps just that one',
    );
    expect(
      endOnDay(_ev('a', 'a', start: d.add(const Duration(days: 1))), d),
      DayTrim.delete,
    );
    expect(
      endOnDay(_ev('a', 'a', mode: RecurrenceMode.once, start: d), d),
      isNull,
    );
    expect(
      endOnDay(_ev('a', 'a', end: EndMode.untilDate, endDate: d), d),
      isNull,
    );
    expect(endOnDay(_ev('a', 'a', enabled: false), d), isNull);
    expect(trimmedEvent(_ev('a', 'a'), d).endDate, d);
  });
}
