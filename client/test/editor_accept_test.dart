// The EventEditor header tick accepts the form the same way Save / Create
// does, after flushing any in-progress Amount from the soft keyboard.
import 'package:budget_client/boot/page_stub.dart' as page;
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _start = DateTime(2026, 11, 1);

BudgetEvent _series() => BudgetEvent(
  id: 't',
  streamId: 'acc',
  name: 'Rent',
  direction: EventDirection.debit,
  amount: Decimal.fromInt(100),
  startDate: _start,
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  version: 1,
);

class _Repo extends EventRepository {
  _Repo({this.existing}) : super(ApiClient());
  BudgetEvent? existing;
  final created = <BudgetEvent>[];
  final updated = <BudgetEvent>[];

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async =>
      [?existing];

  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    created.add(draft);
    return draft;
  }

  @override
  Future<BudgetEvent> update(BudgetEvent x, {bool force = false}) async {
    updated.add(x);
    return existing = x;
  }
}

Future<(_Repo, List<EditorOutcome?>)> _pump(
  WidgetTester tester, {
  BudgetEvent? existing,
  bool readOnly = false,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _Repo(existing: existing);
  final outcomes = <EditorOutcome?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
            'Rent',
          ]),
        ),
        eventRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'acc',
            existing: existing,
            initialDate: _start,
            readOnly: readOnly,
            onDone: outcomes.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, outcomes);
}

Finder get _tick => find.byKey(const ValueKey('editor-accept'));

void main() {
  setUp(() {
    page.flushSoftKeyboardCalls = 0;
    page.pendingSoftKeyboardText = null;
    page.softKeyboardTextHandler = null;
  });

  testWidgets('New and Edit both show a header tick beside Close', (
    tester,
  ) async {
    await _pump(tester);
    expect(_tick, findsOneWidget);
    expect(find.byKey(const ValueKey('editor-close')), findsOneWidget);
    final tick = tester.widget<IconButton>(_tick);
    expect(tick.tooltip, 'Create');
    expect(tick.icon, isA<Icon>());
    expect((tick.icon as Icon).icon, Icons.check_rounded);

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, existing: _series());
    expect(_tick, findsOneWidget);
    expect(tester.widget<IconButton>(_tick).tooltip, 'Save');
  });

  testWidgets('View-only has no tick', (tester) async {
    await _pump(tester, existing: _series(), readOnly: true);
    expect(_tick, findsNothing);
  });

  testWidgets('The tick creates a new transaction with the current Amount', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '42.5');
    await tester.pump();
    await tester.tap(_tick);
    await tester.pumpAndSettle();
    expect(page.flushSoftKeyboardCalls, 1);
    expect(repo.created, hasLength(1));
    expect(repo.created.single.amount, Decimal.parse('42.5'));
    expect(outcomes, hasLength(1));
    expect(outcomes.single!.action, EditorAction.created);
  });

  testWidgets('A missing amount shows the same error and stays open', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester);
    await tester.tap(_tick);
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount'), findsOneWidget);
    expect(repo.created, isEmpty);
    expect(outcomes, isEmpty);
    expect(find.byKey(const ValueKey('editor-header')), findsOneWidget);
  });

  testWidgets('An invalid amount shows the same error and stays open', (
    tester,
  ) async {
    final (repo, _) = await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '0');
    await tester.pump();
    await tester.tap(_tick);
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount above zero'), findsOneWidget);
    expect(repo.created, isEmpty);
  });

  testWidgets(
    'Flushing the soft-keyboard text commits the in-progress Amount',
    (tester) async {
      final (repo, outcomes) = await _pump(tester);
      expect(page.softKeyboardTextHandler, isNotNull);
      page.pendingSoftKeyboardText = '25.50';
      await tester.tap(_tick);
      await tester.pumpAndSettle();
      expect(page.flushSoftKeyboardCalls, 1);
      expect(repo.created, hasLength(1));
      expect(repo.created.single.amount, Decimal.parse('25.50'));
      expect(outcomes.single!.action, EditorAction.created);
    },
  );

  testWidgets('On an existing transaction the tick saves like Save', (
    tester,
  ) async {
    final (repo, outcomes) = await _pump(tester, existing: _series());
    await tester.enterText(find.byKey(const ValueKey('editor-amount')), '80');
    await tester.pump();
    await tester.tap(_tick);
    await tester.pumpAndSettle();
    expect(repo.updated, hasLength(1));
    expect(repo.updated.single.amount, Decimal.fromInt(80));
    expect(outcomes.single!.action, EditorAction.saved);
  });
}
