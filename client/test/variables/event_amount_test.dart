// The event editor's amount is a FormulaField (spec 011 group 2 / 013):
// a formula is saved as its text for the server to resolve, opening a
// formula event shows the formula, and plain numbers behave as before.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/formula/formula_controller.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/formula_support.dart' show typeText, suggestion;
import '../support/category_dropdown.dart';
import '../support/fake_categories.dart';
import 'manager_support.dart';

final _start = DateTime(2026, 10, 5);
final _focus = DateTime(2026, 10, 19);

BudgetEvent _rent({String? expr = 'rent', Map<String, dynamic>? errors}) =>
    BudgetEvent(
      id: 't',
      streamId: 'acc',
      name: 'Rent',
      direction: EventDirection.debit,
      amount: Decimal.fromInt(1200),
      amountExpr: expr,
      exprErrors: errors,
      startDate: _start,
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      version: 3,
    );

class _Events extends EventRepository {
  _Events(this.t) : super(ApiClient(baseUrl: 'http://x'));
  BudgetEvent? t;

  /// What each write would send (the create / patch body).
  final sent = <Map<String, dynamic>>[];
  final calls = <String>[];
  bool resolveDifferently = false;

  BudgetEvent _answer(BudgetEvent x) => BudgetEvent.fromJson({
    ...x.toJson(),
    if (resolveDifferently) 'amount': '1250',
    if (resolveDifferently) 'formulaResolvedDifferently': true,
  });

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [?t];

  @override
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    calls.add('create');
    sent.add(draft.toCreateJson());
    return _answer(draft);
  }

  @override
  Future<BudgetEvent> update(BudgetEvent x, {bool force = false}) async {
    calls.add('update');
    sent.add(x.toCreateJson());
    return t = _answer(x);
  }

  @override
  Future<BudgetEvent> setOverride(
    String eventId,
    DateTime date, {
    required EventDirection direction,
    required Decimal amount,
    String? amountExpr,
    int? version,
  }) async {
    calls.add('override ${formatDate(date)} $amount $amountExpr');
    return t!;
  }

  @override
  Future<({BudgetEvent original, BudgetEvent? created})> split(
    BudgetEvent edited,
    DateTime date, {
    bool force = false,
  }) async {
    calls.add(
      'split ${formatDate(date)} ${edited.amount} ${edited.amountExpr}',
    );
    return (
      original: t!.copyWith(
        endMode: EndMode.untilDate,
        endDate: date.subtract(const Duration(days: 1)),
      ),
      created: edited.copyWith(id: 't2', startDate: date),
    );
  }
}

Finder k(String key) => find.byKey(ValueKey(key));
final _amount = k('editor-amount');

String _text(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _amount, matching: find.byType(EditableText)),
    )
    .controller
    .text;

Future<_Events> _pump(
  WidgetTester tester, {
  BudgetEvent? existing,
  DateTime? focus,
  bool on = true,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  ServerFeatures.variables = on;
  final repo = _Events(existing);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        eventRepositoryProvider.overrideWithValue(repo),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
            'Groceries',
          ]),
        ),
        variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
        streamRepositoryProvider.overrideWithValue(FakeStreams(Role.owner)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'acc',
            existing: existing,
            focusDate: focus,
            onDone: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

Future<void> _type(WidgetTester tester, String v) async {
  await tester.enterText(_amount, v);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(k('editor-save'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => ServerFeatures.variables = false);

  testWidgets('new event: amount is focused first and takes a formula', (
    tester,
  ) async {
    final repo = await _pump(tester);
    final field = tester.widget<EditableText>(
      find.descendant(of: _amount, matching: find.byType(EditableText)),
    );
    expect(field.focusNode.hasFocus, isTrue);
    expect(field.controller, isA<FormulaEditingController>());
    await pickCategory(tester, fakeCategoryId('Groceries'));
    await _type(tester, 'rent * 2');
    await _save(tester);
    expect(repo.calls, ['create']);
    expect(repo.sent.single['amount'], '2400');
    expect(repo.sent.single['amountExpr'], 'rent * 2');
  });

  testWidgets('a plain number sends no formula', (tester) async {
    final repo = await _pump(tester);
    await pickCategory(tester, fakeCategoryId('Groceries'));
    await _type(tester, '1,250.50');
    await _save(tester);
    expect(repo.sent.single['amount'], '1250.5');
    expect(repo.sent.single.containsKey('amountExpr'), isFalse);
  });

  testWidgets('opening a formula event shows the formula, not the number', (
    tester,
  ) async {
    await _pump(tester, existing: _rent());
    expect(_text(tester), 'rent');
    expect(find.text('1200'), findsNothing);
  });

  testWidgets('without the server feature it shows the number', (tester) async {
    await _pump(tester, existing: _rent(), on: false);
    expect(_text(tester), '1200');
  });

  testWidgets('a category-only edit keeps the formula', (tester) async {
    final repo = await _pump(tester, existing: _rent());
    await pickCategory(tester, fakeCategoryId('Groceries'));
    await _save(tester);
    expect(repo.calls, ['update']);
    expect(repo.sent.single['amountExpr'], 'rent');
    expect(repo.sent.single['amount'], '1200');
  });

  testWidgets('replacing a formula with a number clears it', (tester) async {
    final repo = await _pump(tester, existing: _rent());
    await _type(tester, '1300');
    await _save(tester);
    expect(repo.sent.single['amount'], '1300');
    expect(repo.sent.single.containsKey('amountExpr'), isFalse);
  });

  testWidgets('server resolved differently: says what was saved', (
    tester,
  ) async {
    final repo = await _pump(tester, existing: _rent());
    repo.resolveDifferently = true;
    await _type(tester, 'rent + 1');
    await _save(tester);
    expect(k('editor-resolved-differently'), findsOneWidget);
    expect(
      find.textContaining('a variable changed while you were editing'),
      findsOneWidget,
    );
  });

  testWidgets('a broken formula is flagged and blocks saving', (tester) async {
    final repo = await _pump(
      tester,
      existing: _rent(
        expr: 'gone',
        errors: {
          'amount': {'code': 'unknown', 'message': 'Unknown variable gone'},
        },
      ),
    );
    expect(_text(tester), 'gone');
    await _save(tester);
    expect(repo.calls, isEmpty);
    expect(find.textContaining('Unknown variable'), findsWidgets);
  });

  testWidgets('once-off and From now on send the formula', (tester) async {
    var repo = await _pump(tester, existing: _rent(expr: null), focus: _focus);
    await _type(tester, 'rent + 50');
    await tester.tap(k('editor-save-menu'));
    await tester.pumpAndSettle();
    await tester.tap(k('save-option-once'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['override 2026-10-19 1250 rent + 50']);

    repo = await _pump(tester, existing: _rent(expr: null), focus: _focus);
    await _type(tester, 'rent + 50');
    await tester.tap(k('editor-save-menu'));
    await tester.pumpAndSettle();
    await tester.tap(k('save-option-forward'));
    await tester.pumpAndSettle();
    expect(repo.calls, ['split 2026-10-19 1250 rent + 50']);
  });

  testWidgets(r'$ suggests the stream variables; a new name offers Create', (
    tester,
  ) async {
    await _pump(tester);
    await typeText(tester, 're');
    expect(suggestion('rent'), findsOneWidget);
    await typeText(tester, 'parking');
    expect(k('formula-create-variable'), findsOneWidget);
    await tester.tap(k('formula-create-variable'));
    await tester.pumpAndSettle();
    expect(k('variables-manager'), findsOneWidget);
  });
}
