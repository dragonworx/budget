// Events list include checkboxes: click toggles; press and drag
// across rows paints them all to the pressed row's new value (sets, never
// toggles), saved in one batch with one timeline refresh; failures roll
// back. Works scrolled, with touch (a drag from an eye paints instead
// of scrolling) and from the keyboard.
import 'dart:async';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/events_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:budget_client/widgets/eye_icons.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _stream = BudgetStream(
  id: 'p',
  ownerId: 'u1',
  name: 'Everyday',
  seedBalance: Decimal.parse('1000'),
  seedDate: DateTime(2026, 1, 1),
  lossThreshold: Decimal.zero,
  role: Role.owner,
);

BudgetEvent _tx(int i, {bool enabled = true}) => BudgetEvent(
  id: 't$i',
  streamId: 'p',
  name: 'Item $i',
  direction: EventDirection.debit,
  amount: Decimal.fromInt(10 + i),
  startDate: DateTime(2026, 2, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  enabled: enabled,
);

class _StreamRepo extends StreamRepository {
  _StreamRepo() : super(ApiClient());
  @override
  Future<BudgetStream> get(String id) async => _stream;
}

class _TxRepo extends EventRepository {
  _TxRepo(this.items) : super(ApiClient());
  List<BudgetEvent> items;
  final calls = <String>[];
  final fail = <String>{};
  Completer<void>? gate;

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => items;

  @override
  Future<BudgetEvent> setEnabled(String id, bool enabled) async {
    calls.add('$id=$enabled');
    if (gate != null) await gate!.future;
    if (fail.contains(id)) throw ApiException('boom', statusCode: 500);
    final t = items.firstWhere((t) => t.id == id).copyWith(enabled: enabled);
    items = [for (final x in items) x.id == id ? t : x];
    return t;
  }
}

late _TxRepo _repo;
var _changed = 0;

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(1000, 800),
  int count = 24,
  Set<int> disabled = const {},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _changed = 0;
  _repo = _TxRepo([
    for (var i = 0; i < count; i++) _tx(i, enabled: !disabled.contains(i)),
  ]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_StreamRepo()),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider)),
        ),
        eventRepositoryProvider.overrideWithValue(_repo),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventsPanel(
            stream: _stream,
            skipsFor: (_) => const {},
            onPanelClosed: (_) {},
            onChanged: () => _changed++,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _box(int i) => find.byKey(ValueKey('row-eye-t$i'));

/// The row's eye shows "shown" (eye) rather than "hidden" (eye-off).
bool _checked(WidgetTester tester, int i) {
  final shown = find
      .descendant(of: _box(i), matching: find.byIcon(eventShownIcon))
      .evaluate()
      .isNotEmpty;
  final hidden = find
      .descendant(of: _box(i), matching: find.byIcon(eventHiddenIcon))
      .evaluate()
      .isNotEmpty;
  expect(shown != hidden, isTrue, reason: 'one icon per row');
  return shown;
}

Finder get _listFinder =>
    find.ancestor(of: _box(0), matching: find.byType(Scrollable)).first;

ScrollPosition _list(WidgetTester tester) =>
    tester.state<ScrollableState>(_listFinder).position;

/// Saved include state (after the batch lands).
bool _saved(int i) => _repo.items.firstWhere((t) => t.id == 't$i').enabled;

void main() {
  testWidgets('a click toggles one row, saved once', (tester) async {
    await _pump(tester);
    expect(find.byType(Switch), findsNothing);
    expect(_checked(tester, 1), isTrue);
    await tester.tap(_box(1), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_checked(tester, 1), isFalse);
    expect(_repo.calls, ['t1=false']);
    expect(_changed, 1);
    // Back on: a second click.
    await tester.tap(_box(1), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(_checked(tester, 1), isTrue);
    expect(_saved(1), isTrue);
    // The row didn't open in the editor.
    expect(find.byKey(const ValueKey('events-search')), findsOneWidget);
  });

  testWidgets('press and drag across rows sets them all, one batch', (
    tester,
  ) async {
    // Row 2 is already excluded: painting "exclude" leaves it (sets, not
    // toggles) and sends nothing for it.
    await _pump(tester, disabled: {2});
    final g = await tester.startGesture(
      tester.getCenter(_box(0)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(_checked(tester, 0), isFalse, reason: 'flips on press');
    for (var i = 1; i <= 4; i++) {
      await g.moveTo(tester.getCenter(_box(i)));
      await tester.pump();
    }
    // Nothing saved mid-drag; the rows already show it.
    expect(_repo.calls, isEmpty);
    for (var i = 0; i <= 4; i++) {
      expect(_checked(tester, i), isFalse, reason: 'row $i');
    }
    expect(_checked(tester, 5), isTrue);
    await g.up();
    await tester.pumpAndSettle();
    expect(_repo.calls.toSet(), {
      't0=false',
      't1=false',
      't3=false',
      't4=false',
    });
    expect(_changed, 1, reason: 'the timeline refreshes once');
    for (var i = 0; i <= 4; i++) {
      expect(_saved(i), isFalse);
    }
    expect(_saved(5), isTrue);
  });

  testWidgets('dragging back over a row keeps it set; drags back up too', (
    tester,
  ) async {
    await _pump(tester, disabled: {0, 1, 2, 3});
    // Start on 3 (excluded → include) and paint upwards to 0.
    final g = await tester.startGesture(
      tester.getCenter(_box(3)),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(_box(0)));
    await g.moveTo(tester.getCenter(_box(2)));
    await g.up();
    await tester.pumpAndSettle();
    for (var i = 0; i <= 3; i++) {
      expect(_saved(i), isTrue, reason: 'row $i');
    }
  });

  testWidgets('a fast flick skips no rows', (tester) async {
    await _pump(tester);
    final g = await tester.startGesture(
      tester.getCenter(_box(0)),
      kind: PointerDeviceKind.mouse,
    );
    // One move event straight from row 0 to row 7, off to the side.
    await g.moveTo(tester.getCenter(_box(7)) + const Offset(-300, 0));
    await g.up();
    await tester.pumpAndSettle();
    for (var i = 0; i <= 7; i++) {
      expect(_saved(i), isFalse, reason: 'row $i');
    }
    expect(_saved(8), isTrue);
    expect(_repo.calls, hasLength(8));
  });

  testWidgets('works when the list is scrolled', (tester) async {
    await _pump(tester, count: 40);
    _list(tester).jumpTo(900);
    await tester.pumpAndSettle();
    final first = [
      for (var i = 0; i < 40; i++)
        if (_box(i).evaluate().isNotEmpty && tester.getCenter(_box(i)).dy > 200)
          i,
    ].first;
    expect(first, greaterThan(5));
    final g = await tester.startGesture(
      tester.getCenter(_box(first)),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(_box(first + 3)));
    await g.up();
    await tester.pumpAndSettle();
    for (var i = 0; i < 40; i++) {
      expect(
        _saved(i),
        i < first || i > first + 3,
        reason: 'row $i (painted $first..${first + 3})',
      );
    }
  });

  testWidgets('dragging past the list edge auto-scrolls the list', (
    tester,
  ) async {
    await _pump(tester, count: 40);
    final pos = _list(tester);
    expect(pos.pixels, 0);
    final bottom = tester.getBottomLeft(_listFinder).dy;
    final g = await tester.startGesture(
      tester.getCenter(_box(2)),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(Offset(tester.getCenter(_box(2)).dx, bottom - 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(pos.pixels, greaterThan(100));
    await g.up();
    await tester.pumpAndSettle();
    // Every row from 2 down to the one now at the edge, none skipped.
    final changed = [
      for (var i = 0; i < 40; i++)
        if (!_saved(i)) i,
    ];
    expect(changed.first, 2);
    expect(changed, [for (var i = 2; i <= changed.last; i++) i]);
    expect(changed.length, greaterThan(5));
  });

  testWidgets('touch: a drag from an eye paints instead of scrolling; '
      'elsewhere it scrolls', (tester) async {
    await _pump(tester, size: const Size(390, 844), count: 30);
    final pos = _list(tester);
    final g = await tester.startGesture(tester.getCenter(_box(1)));
    for (var i = 2; i <= 4; i++) {
      await g.moveTo(tester.getCenter(_box(i)));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(pos.pixels, 0, reason: 'the list did not scroll');
    for (var i = 1; i <= 4; i++) {
      expect(_saved(i), isFalse, reason: 'row $i');
    }
    expect(_saved(0), isTrue);
    expect(_changed, 1);
    // A drag on the row's name scrolls as before.
    await tester.drag(find.text('Item 6'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(100));
    expect(_repo.calls, hasLength(4));
  });

  testWidgets('a failed save rolls those rows back', (tester) async {
    await _pump(tester);
    _repo.fail.add('t2');
    _repo.gate = Completer();
    final g = await tester.startGesture(
      tester.getCenter(_box(1)),
      kind: PointerDeviceKind.mouse,
    );
    await g.moveTo(tester.getCenter(_box(3)));
    await g.up();
    await tester.pump();
    // Optimistic while the batch is in flight.
    for (var i = 1; i <= 3; i++) {
      expect(_checked(tester, i), isFalse);
    }
    _repo.gate!.complete();
    await tester.pumpAndSettle();
    expect(_checked(tester, 1), isFalse);
    expect(_checked(tester, 2), isTrue, reason: 'rolled back');
    expect(_checked(tester, 3), isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_changed, 1);
  });

  testWidgets('no checkboxes left; Space / Enter toggle a focused eye; it '
      'reads as a toggle named for the event', (tester) async {
    final sem = tester.ensureSemantics();
    await _pump(tester);
    expect(find.byType(Checkbox), findsNothing);
    final button = find.descendant(
      of: _box(0),
      matching: find.byType(IconButton),
    );
    expect(
      tester.getSemantics(button),
      matchesSemantics(
        label: 'Show Item 0 (on the timeline and in the balance)',
        hasToggledState: true,
        isToggled: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    Focus.of(
      tester.element(find.descendant(of: button, matching: find.byType(Icon))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_checked(tester, 0), isFalse);
    expect(_repo.calls, ['t0=false']);
    expect(_changed, 1);
    expect(
      tester.getSemantics(button),
      matchesSemantics(
        label: 'Show Item 0 (on the timeline and in the balance)',
        hasToggledState: true,
        isToggled: false,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_checked(tester, 0), isTrue);
    sem.dispose();
  });

  testWidgets('phone: the eye is a 44px target; a hidden row shows eye-off, '
      'dimmed, still two lines; Show N hidden shows them all in one batch', (
    tester,
  ) async {
    await _pump(tester, size: const Size(390, 844), count: 4, disabled: {1, 2});
    expect(tester.getSize(_box(0)), const Size(44, 44));
    expect(_checked(tester, 0), isTrue);
    expect(_checked(tester, 1), isFalse);
    expect(
      tester.getSize(find.byKey(const ValueKey('dismiss-t1'))),
      tester.getSize(find.byKey(const ValueKey('dismiss-t0'))),
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('row-line2-t1'))).maxLines,
      1,
    );
    // Dimmed: the hidden row's name is faint.
    final name = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('row-line1-t1')),
        matching: find.text('Item 1'),
      ),
    );
    expect(name.style?.color, AppTheme.textFaint);
    expect(find.text('Show 2 hidden'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('show-all-hidden')));
    await tester.pumpAndSettle();
    expect(_repo.calls..sort(), ['t1=true', 't2=true']);
    expect(_changed, 1, reason: 'one refresh for the batch');
    expect(_checked(tester, 1), isTrue);
    expect(find.byKey(const ValueKey('show-all-hidden')), findsNothing);
  });

  testWidgets('hiding the first event never shifts the rows (the Show N '
      'hidden chip sits below the list)', (tester) async {
    await _pump(tester, count: 4);
    final before = tester.getRect(_box(2));
    await tester.tap(_box(0));
    await tester.pumpAndSettle();
    expect(find.text('Show 1 hidden'), findsOneWidget);
    expect(tester.getRect(_box(2)), before);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('show-all-hidden'))).dy,
      greaterThan(tester.getBottomLeft(_box(3)).dy),
    );
  });

  testWidgets('reorder handles still drag rows', (tester) async {
    await _pump(tester, count: 6);
    final handle = find.byIcon(Icons.drag_indicator_rounded).first;
    expect(handle, findsOneWidget);
    // The handle sits apart from the eye; pressing it paints nothing.
    final g = await tester.startGesture(tester.getCenter(handle));
    await g.moveBy(const Offset(0, 40));
    await g.up();
    await tester.pumpAndSettle();
    expect(_repo.calls, isEmpty);
  });
}
