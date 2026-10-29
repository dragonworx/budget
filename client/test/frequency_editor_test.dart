// Event editor schedule: one frequency picker (Once · Daily · Weekly ·
// Every N weeks · Monthly · Every N months) with an inline N stepper, day
// chips (Mon–Sun row / 1–31 grid) that fade in for the week and month
// families, paint-drag across chips, and the live phrase. Every former
// preset (weekly, fortnightly, monthly, quarterly, yearly …) opens as its
// rule and saves unchanged.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:budget_client/data/frequency.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_streams.dart';

import 'support/fake_categories.dart';

class _Txs extends EventRepository {
  _Txs() : super(ApiClient());
  final saved = <BudgetEvent>[];
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [];
  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    saved.add(draft);
    return draft;
  }

  @override
  Future<BudgetEvent> update(BudgetEvent t, {bool force = false}) async {
    saved.add(t);
    return t;
  }
}

BudgetEvent _series(
  int? interval,
  RecurrenceUnit? unit, {
  List<int> days = const [],
}) => BudgetEvent(
  id: 't1',
  streamId: 'a',
  name: 'Rent',
  direction: EventDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: DateTime(2026, 10, 20),
  recurrenceMode: interval == null ? RecurrenceMode.once : RecurrenceMode.every,
  interval: interval,
  unit: unit,
  days: days,
  endMode: EndMode.never,
  version: 1,
);

Future<_Txs> _pump(
  WidgetTester tester, {
  BudgetEvent? existing,
  Size size = const Size(390, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final txs = _Txs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(FakeStreamRepository()),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
            'Pay',
          ]),
        ),
        eventRepositoryProvider.overrideWithValue(txs),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'a',
            existing: existing,
            initialDate: DateTime(2026, 10, 20),
            onDone: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return txs;
}

String _intervalText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('editor-interval')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

Future<void> _touch(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  final g = await tester.startGesture(
    tester.getCenter(f),
    kind: PointerDeviceKind.touch,
  );
  await g.up();
  await tester.pumpAndSettle();
}

Finder _k(String k) => find.byKey(ValueKey(k));

String _phrase(WidgetTester tester) =>
    tester.widget<Text>(_k('editor-freq-phrase')).data!;

bool _on(WidgetTester tester, int d) =>
    tester.widget<Semantics>(_k('editor-day-$d')).properties.toggled ?? false;

Set<int> _onDays(WidgetTester tester, int n) => {
  for (var d = 1; d <= n; d++)
    if (_on(tester, d)) d,
};

Future<void> _pick(WidgetTester tester, String rule) =>
    _touch(tester, _k('editor-freq-$rule'));

/// Presses at chip [from], moves through [via] chip centres (one pointer
/// event each), lifts.
Future<void> _drag(
  WidgetTester tester,
  int from,
  List<int> via, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  await tester.ensureVisible(_k('editor-days'));
  await tester.pumpAndSettle();
  final g = await tester.startGesture(
    tester.getCenter(_k('editor-day-$from')),
    kind: kind,
    buttons: kPrimaryButton,
  );
  await tester.pump();
  for (final d in via) {
    await g.moveTo(tester.getCenter(_k('editor-day-$d')));
    await tester.pump();
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final preset in FrequencyPreset.repeating) {
    testWidgets('${preset.label} opens as its rule and saves unchanged', (
      tester,
    ) async {
      final saved = _series(preset.interval, preset.unit);
      final txs = await _pump(tester, existing: saved);
      final rule = saved.frequency.rule;
      expect(
        tester.widget<ChoiceChip>(_k('editor-freq-${rule.apiName}')).selected,
        isTrue,
      );
      if (rule.takesInterval) {
        expect(_intervalText(tester), '${saved.frequency.interval}');
      }
      expect(
        _phrase(tester),
        describeFrequency(saved.frequency, DateTime.utc(2026, 10, 20)),
      );
      await _touch(tester, _k('editor-save'));
      // Unchanged: nothing to save, or saved with the same rule.
      for (final t in txs.saved) {
        expect(t.frequency, saved.frequency);
      }
    });
  }

  testWidgets('a non-preset schedule (every 5 weeks on Mon, Wed) round-trips', (
    tester,
  ) async {
    final saved = _series(5, RecurrenceUnit.weeks, days: [1, 3]);
    await _pump(tester, existing: saved);
    expect(
      tester.widget<ChoiceChip>(_k('editor-freq-every_n_weeks')).selected,
      isTrue,
    );
    expect(_intervalText(tester), '5');
    expect(_onDays(tester, 7), {1, 3});
    expect(_phrase(tester), 'Every 5 weeks on Mon, Wed');
  });

  testWidgets('a one-off opens as Once: no chips, no stepper', (tester) async {
    await _pump(tester, existing: _series(null, null));
    expect(tester.widget<ChoiceChip>(_k('editor-freq-once')).selected, isTrue);
    expect(_k('editor-interval'), findsNothing);
    expect(_k('editor-days'), findsNothing);
    expect(_phrase(tester), 'Once on 20 Oct 2026');
  });

  testWidgets('chips fade in only for the week and month families; the '
      'start date stays in place; no dialogs', (tester) async {
    await _pump(tester);
    final startAt = tester.getTopLeft(_k('editor-start'));
    expect(_phrase(tester), 'Once on 20 Oct 2026');
    await _pick(tester, 'daily');
    expect(_k('editor-days'), findsNothing);
    expect(_phrase(tester), 'Every day');
    await _pick(tester, 'weekly');
    expect(_k('editor-day-7'), findsOneWidget);
    expect(_k('editor-day-8'), findsNothing);
    await _pick(tester, 'every_n_weeks');
    expect(_k('editor-day-7'), findsOneWidget);
    expect(_intervalText(tester), '2');
    await _pick(tester, 'monthly');
    expect(_k('editor-day-31'), findsOneWidget);
    await _pick(tester, 'every_n_months');
    expect(_k('editor-day-31'), findsOneWidget);
    await _pick(tester, 'once');
    expect(_k('editor-days'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.ensureVisible(_k('editor-start'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_k('editor-start')).dx, startAt.dx);
    // The start field still comes before the picker.
    expect(
      tester.getTopLeft(_k('editor-start')).dy,
      lessThan(tester.getTopLeft(_k('editor-freq')).dy),
    );
  });

  testWidgets('tap single toggles one chip (touch and mouse); the phrase '
      'follows in weekday order', (tester) async {
    await _pump(tester);
    await _pick(tester, 'weekly');
    expect(_phrase(tester), 'Every week');
    await _drag(tester, 2, const []);
    expect(_onDays(tester, 7), {2});
    await _drag(tester, 1, const [], kind: PointerDeviceKind.mouse);
    expect(_onDays(tester, 7), {1, 2});
    expect(_phrase(tester), 'Every week on Mon, Tue');
    await _drag(tester, 2, const []);
    expect(_onDays(tester, 7), {1});
    expect(_phrase(tester), 'Every week on Mon');
  });

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('${kind.name}: drag add paints every chip passed', (
      tester,
    ) async {
      await _pump(tester);
      await _pick(tester, 'weekly');
      await _drag(tester, 1, const [2, 3, 4], kind: kind);
      expect(_onDays(tester, 7), {1, 2, 3, 4});
      expect(_phrase(tester), 'Every week on Mon, Tue, Wed, Thu');
    });

    testWidgets('${kind.name}: drag remove: the first chip\'s new state '
        '(off) applies to the rest, unselected ones stay off', (tester) async {
      await _pump(
        tester,
        existing: _series(1, RecurrenceUnit.weeks, days: [1, 2, 4, 5]),
      );
      await _drag(tester, 2, const [3, 4, 5], kind: kind);
      expect(_onDays(tester, 7), {1});
    });
  }

  testWidgets('drag across grid rows (1 → 8 → 15 → 16), and a fast '
      'single-event drag interpolates (no chip skipped)', (tester) async {
    final txs = await _pump(tester);
    await _pick(tester, 'monthly');
    await _drag(tester, 1, const [8, 15, 16]);
    expect(_onDays(tester, 31), {1, 8, 15, 16});
    expect(_phrase(tester), 'Monthly on the 1st, 8th, 15th and 16th');
    // One pointer move from 22 to 28: 23–27 are painted too.
    await _drag(tester, 22, const [28]);
    expect(_onDays(tester, 31), {1, 8, 15, 16, 22, 23, 24, 25, 26, 27, 28});
    // Remove across rows: 8 → 15 → 22 (all on: all off).
    await _drag(tester, 8, const [15, 22]);
    expect(_onDays(tester, 31), {1, 16, 23, 24, 25, 26, 27, 28});
    await tester.enterText(_k('editor-amount'), '20');
    await tester.pumpAndSettle();
    await _touch(tester, _k('editor-save'));
    expect(txs.saved.last.days, [1, 16, 23, 24, 25, 26, 27, 28]);
  });

  testWidgets('dragging on the chips never scrolls the editor', (tester) async {
    await _pump(tester, size: const Size(390, 640));
    await _pick(tester, 'monthly');
    await tester.ensureVisible(_k('editor-day-1'));
    await tester.pumpAndSettle();
    final scroll = Scrollable.of(tester.element(_k('editor-days'))).position;
    final before = scroll.pixels;
    final top = tester.getTopLeft(_k('editor-day-1'));
    // Straight down the first column, past the grid's bottom.
    final g = await tester.startGesture(
      tester.getCenter(_k('editor-day-1')),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 1; i <= 10; i++) {
      await g.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(scroll.pixels, before);
    expect(tester.getTopLeft(_k('editor-day-1')), top);
    expect(_onDays(tester, 31), containsAll(<int>{1, 8, 15, 22, 29}));
  });

  testWidgets('phrase: ordinals and ordering; 31st notes the short-month '
      'roll; Every N months', (tester) async {
    await _pump(tester);
    await _pick(tester, 'monthly');
    await _drag(tester, 15, const []);
    await _drag(tester, 1, const []);
    expect(_phrase(tester), 'Monthly on the 1st and 15th');
    await _drag(tester, 22, const []);
    await _drag(tester, 3, const []);
    await _drag(tester, 2, const []);
    expect(_phrase(tester), 'Monthly on the 1st, 2nd, 3rd, 15th and 22nd');
    await _pick(tester, 'every_n_months');
    await _touch(tester, _k('editor-interval-plus'));
    for (final d in [1, 2, 3, 15, 22]) {
      await _drag(tester, d, const []);
    }
    await _drag(tester, 31, const []);
    expect(_phrase(tester), 'Every 3 months on the 31st (last day when short)');
  });

  for (final (label, size, min) in [
    ('phone', const Size(390, 1600), 44.0),
    ('desktop', const Size(1440, 1600), 36.0),
  ]) {
    testWidgets('$label: chips are at least ${min.toInt()}px', (tester) async {
      await _pump(tester, size: size);
      await _pick(tester, 'weekly');
      for (var d = 1; d <= 7; d++) {
        final s = tester.getSize(_k('editor-day-$d'));
        expect(s.height, greaterThanOrEqualTo(min), reason: 'weekday $d');
        expect(s.width, greaterThanOrEqualTo(min), reason: 'weekday $d');
      }
      await _pick(tester, 'monthly');
      for (var d = 1; d <= 31; d++) {
        final s = tester.getSize(_k('editor-day-$d'));
        expect(s.height, greaterThanOrEqualTo(min), reason: 'day $d');
        expect(s.width, greaterThanOrEqualTo(min), reason: 'day $d');
      }
    });
  }

  testWidgets('touch: Every N weeks steps 2…99 with ≥44px buttons; the new '
      'rule and days save, the payload carries the structured rule', (
    tester,
  ) async {
    final txs = await _pump(tester);
    await tester.enterText(_k('editor-amount'), '20');
    await tester.pumpAndSettle();
    await _pick(tester, 'every_n_weeks');
    final minus = _k('editor-interval-minus');
    final plus = _k('editor-interval-plus');
    expect(_intervalText(tester), '2');
    for (final b in [minus, plus]) {
      final size = tester.getSize(b);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(tester.widget<IconButton>(minus).onPressed, isNull);
    await _touch(tester, plus);
    expect(_intervalText(tester), '3');
    await _touch(tester, minus);
    expect(_intervalText(tester), '2');
    await tester.enterText(_k('editor-interval'), '990');
    await tester.pumpAndSettle();
    expect(_intervalText(tester), '99');
    expect(tester.widget<IconButton>(plus).onPressed, isNull);
    await tester.enterText(_k('editor-interval'), '2');
    await tester.pumpAndSettle();
    await _drag(tester, 1, const [2]);
    expect(_phrase(tester), 'Every 2 weeks on Mon, Tue');
    await _touch(tester, _k('editor-save'));
    final t = txs.saved.last;
    expect(t.recurrenceMode, RecurrenceMode.every);
    expect(t.interval, 2);
    expect(t.unit, RecurrenceUnit.weeks);
    expect(t.days, [1, 2]);
    expect(t.toCreateJson()['frequency'], {
      'rule': 'every_n_weeks',
      'interval': 2,
      'days': [1, 2],
    });
  });
}
