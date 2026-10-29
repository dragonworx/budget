// Categories: the model helpers, the manager (pills, ⋮ Edit / Delete /
// Delete N Events, the dashed "+ New category"), the editor's read-only
// picker, the eye menu's Categories section, the Events list's category
// filter, and a plan's own (unique) category name.
import 'dart:math' as math;

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/categories/categories_manager.dart';
import 'package:budget_client/features/events/solve_sheet.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';

final _now = DateTime.now();
final _day = DateTime(_now.year, _now.month, _now.day);

BudgetEvent _ev(String id, String name, {String? color, int amount = 50}) =>
    BudgetEvent(
      id: id,
      streamId: 'acc',
      name: name,
      categoryId: fakeCategoryId(name),
      direction: EventDirection.debit,
      amount: Decimal.fromInt(amount),
      startDate: _day.subtract(const Duration(days: 14)),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      enabled: true,
      color: color,
    );

class _Store {
  final txs = <String, BudgetEvent>{
    'wages': _ev('wages', 'Wages', color: '#5B7A2A', amount: 900),
    'rent': _ev('rent', 'Rent', color: '#3D6FD8'),
    'g1': _ev('g1', 'Groceries', color: '#B36A12', amount: 80),
    'g2': _ev('g2', 'Groceries', color: '#B36A12', amount: 20),
  };
  Role role = Role.owner;
  final calls = <String>[];
  Map<String, BudgetEvent>? before;
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
  Future<BudgetEvent> create(
    String streamId,
    BudgetEvent draft, {
    ({String name, String? color})? newCategory,
  }) async {
    s.calls.add(
      'create ${draft.name} ${draft.categoryId} '
      '${newCategory == null ? '' : 'new:${newCategory.name}'}',
    );
    final id = 'n${s.txs.length}';
    final name = newCategory?.name ?? draft.name;
    return s.txs[id] = draft.copyWith(
      id: id,
      name: name,
      categoryId: newCategory == null
          ? draft.categoryId
          : fakeCategoryId(newCategory.name),
    );
  }

  @override
  Future<void> undoEndAllOn(String streamId, String batchId) async {
    s.calls.add('undo $batchId');
    s.txs
      ..clear()
      ..addAll(s.before!);
  }
}

class _Cats extends FakeCategoryRepository {
  _Cats(this.s, EventRepository events) : super(events);
  final _Store s;

  @override
  Future<({String? batchId, List<String> deleted})> deleteEvents(
    String streamId,
    String id,
  ) async {
    s.before = {...s.txs};
    final gone = [
      for (final e in s.txs.values)
        if (e.categoryId == id) e.id,
    ];
    gone.forEach(s.txs.remove);
    // Keep the (now empty) category listed.
    final c = (await list(streamId)).where((c) => c.id == id).firstOrNull;
    calls.add('deleteEvents $id');
    if (c != null) (extra[streamId] ??= []).add(c);
    return (batchId: 'batch-$id', deleted: gone);
  }

  @override
  Future<void> delete(String streamId, String id) async {
    s.txs.removeWhere((_, e) => e.categoryId == id);
    await super.delete(streamId, id);
  }
}

Future<(_Store, _Cats)> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  Role role = Role.owner,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = _Store()..role = role;
  final events = _EventRepo(store);
  final cats = _Cats(store, events);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_StreamRepo(store)),
        eventRepositoryProvider.overrideWithValue(events),
        categoryRepositoryProvider.overrideWithValue(cats),
      ],
      child: const MaterialApp(home: TimelinePage(streamId: 'acc')),
    ),
  );
  await tester.pumpAndSettle();
  return (store, cats);
}

Future<void> _openManager(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-events')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('panel-categories')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('categories-manager')), findsOneWidget);
}

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
  matchRoot: true,
);

final _wages = fakeCategoryId('Wages');
final _rent = fakeCategoryId('Rent');
final _groc = fakeCategoryId('Groceries');

void main() {
  test('names: trimmed, single-spaced, unique ignoring case, ≤60; a free '
      'default; new colours prefer unused palette ones', () {
    expect(normalizeCategoryName('  Big   shop '), 'Big shop');
    final list = [
      const Category(id: 'a', streamId: 's', name: 'Rent', color: '#3D6FD8'),
      const Category(id: 'b', streamId: 's', name: 'Goal', color: '#9250C8'),
    ];
    expect(categoryNameProblem('rent ', list), isNotNull);
    expect(categoryNameProblem('RENT', list, except: 'a'), isNull);
    expect(categoryNameProblem('   ', list), isNotNull);
    expect(categoryNameProblem('x' * 61, list), isNotNull);
    expect(categoryNameProblem('Wages', list), isNull);
    expect(freeCategoryName('Goal', list), 'Goal 2');
    expect(freeCategoryName('Trip', list), 'Trip');
    for (var seed = 0; seed < 100; seed++) {
      final c = pickCategoryColor(list, math.Random(seed));
      expect(laneColors.map(colorToHex), contains(c));
      expect(['#3D6FD8', '#9250C8'], isNot(contains(c)));
    }
    final j = Category.fromJson({
      'id': 'c',
      'streamId': 's',
      'name': 'Wages',
      'color': '#5b7a2a',
      'hidden': true,
      'eventCount': 3,
    });
    expect((j.name, j.hidden, j.eventCount), ('Wages', true, 3));
  });

  for (final (label, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone', Size(390, 844)),
  ]) {
    testWidgets('$label: the manager shows wrapped pills and a dashed '
        '"+ New category" last; a new name must be unique', (tester) async {
      final (_, cats) = await _pump(tester, size: size);
      await _openManager(tester);
      for (final id in [_wages, _rent, _groc]) {
        expect(find.byKey(ValueKey('category-pill-$id')), findsOneWidget);
      }
      expect(
        tester.widget(find.byKey(const ValueKey('category-pills'))),
        isA<Wrap>(),
      );
      expect(find.byKey(const ValueKey('category-new')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-new-color')), findsOneWidget);
      await tester.enterText(_field('category-new-name'), ' rent ');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-new-error')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('category-new-save')));
      await tester.pumpAndSettle();
      expect(cats.calls.where((c) => c.startsWith('create')), isEmpty);
      await tester.enterText(_field('category-new-name'), 'Fuel');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('category-new-error')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('category-new-save')));
      await tester.pumpAndSettle();
      expect(cats.calls, contains('create Fuel'));
      expect(
        find.byKey(ValueKey('category-pill-${fakeCategoryId('Fuel')}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('⋮ shows exactly Edit, Delete, Delete N Events (N live); '
      'Delete N Events confirms, keeps the category, and Undo restores', (
    tester,
  ) async {
    final (store, cats) = await _pump(tester);
    await _openManager(tester);
    await tester.tap(find.byKey(ValueKey('category-menu-$_groc')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('category-edit-$_groc')), findsOneWidget);
    expect(find.byKey(ValueKey('category-delete-$_groc')), findsOneWidget);
    expect(find.text('Delete 2 Events'), findsOneWidget);
    final items = find.byWidgetPredicate(
      (w) =>
          w is MenuItemButton &&
          w.key is ValueKey<String> &&
          ((w.key! as ValueKey<String>).value.startsWith('category-')),
    );
    expect(items, findsNWidgets(3));
    await tester.tap(find.byKey(ValueKey('category-delete-events-$_groc')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 events?'), findsOneWidget);
    expect(find.textContaining('The category stays.'), findsOneWidget);
    await tester.tap(find.text('Delete 2 events').last);
    await tester.pumpAndSettle();
    expect(cats.calls, contains('deleteEvents $_groc'));
    expect(store.txs.keys, isNot(contains('g1')));
    expect(find.byKey(ValueKey('category-pill-$_groc')), findsOneWidget);
    expect(find.byKey(const ValueKey('category-undo')), findsOneWidget);
    // N is live: 0 now, so the item is disabled.
    await tester.tap(find.byKey(ValueKey('category-menu-$_groc')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.byKey(ValueKey('category-delete-events-$_groc')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(ValueKey('category-menu-$_groc'))); // closes
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-undo-button')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('undo batch-$_groc'));
    expect(store.txs.keys, containsAll(['g1', 'g2']));
  });

  testWidgets('Delete: the confirmation names the category and its event '
      'count; confirming deletes both', (tester) async {
    final (store, cats) = await _pump(tester);
    await _openManager(tester);
    await tester.tap(find.byKey(ValueKey('category-menu-$_groc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('category-delete-$_groc')));
    await tester.pumpAndSettle();
    expect(find.text('Delete category "Groceries"?'), findsOneWidget);
    expect(find.textContaining('all 2 events in it'), findsOneWidget);
    // Cancel first: nothing happens.
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(cats.calls.where((c) => c.startsWith('delete')), isEmpty);
    await tester.tap(find.byKey(ValueKey('category-menu-$_groc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('category-delete-$_groc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete category and events'));
    await tester.pumpAndSettle();
    expect(cats.calls, contains('delete $_groc'));
    expect(store.txs.keys, isNot(contains('g2')));
    expect(find.byKey(ValueKey('category-pill-$_groc')), findsNothing);
  });

  testWidgets('Edit renames / recolours through the API', (tester) async {
    final (_, cats) = await _pump(tester);
    await _openManager(tester);
    await tester.tap(find.byKey(ValueKey('category-menu-$_rent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('category-edit-$_rent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-edit-dialog')), findsOneWidget);
    await tester.enterText(_field('category-edit-name'), 'Wages');
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsNothing);
    await tester.enterText(_field('category-edit-name'), 'Housing');
    await tester.tap(find.byKey(const ValueKey('category-swatch-5')));
    await tester.tap(find.byKey(const ValueKey('category-edit-save')));
    await tester.pumpAndSettle();
    expect(
      cats.calls.where((c) => c.startsWith('update $_rent Housing')),
      hasLength(1),
    );
  });

  testWidgets('viewers: pills only (no ⋮, no new pill)', (tester) async {
    await _pump(tester, role: Role.viewer);
    await _openManager(tester);
    expect(find.byKey(ValueKey('category-pill-$_rent')), findsOneWidget);
    expect(find.byKey(ValueKey('category-menu-$_rent')), findsNothing);
    expect(find.byKey(const ValueKey('category-new')), findsNothing);
  });

  testWidgets('the editor: category is a read-only picker after the type; '
      'the header wears its colour; Manage opens the manager', (tester) async {
    final (store, _) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-new-event')));
    await tester.pumpAndSettle();
    final picker = find.byKey(const ValueKey('editor-category'));
    expect(picker, findsOneWidget);
    expect(
      find.descendant(of: picker, matching: find.byType(TextField)),
      findsNothing,
    );
    expect(
      tester.getTopLeft(picker).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('editor-kind'))).dy,
      ),
    );
    await tester.tap(find.byKey(ValueKey('editor-category-$_groc')));
    await tester.pumpAndSettle();
    final header = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('editor-header')),
    );
    expect(
      (header.decoration! as BoxDecoration).color,
      colorFromHex('#B36A12'),
    );
    await tester.enterText(_field('editor-amount'), '12');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(store.calls.last, startsWith('create Groceries $_groc'));
    await tester.pump(const Duration(seconds: 6));
    // Next time: the last used category is the default.
    await tester.tap(find.byKey(const ValueKey('panel-new-event')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Semantics>(find.byKey(ValueKey('editor-category-$_groc')))
          .properties
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('editor-manage-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('categories-manager')), findsOneWidget);
  });

  testWidgets('eye menu: a Categories section (apart from streams) toggles '
      'a category\'s visibility', (tester) async {
    final (_, cats) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('fit-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('categories-heading')), findsOneWidget);
    final toggle = find.descendant(
      of: find.byKey(ValueKey('view-category-$_rent')),
      matching: find.byType(CheckboxMenuButton),
    );
    expect(tester.widget<CheckboxMenuButton>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(cats.calls, contains('update $_rent   true'));
    expect(tester.widget<CheckboxMenuButton>(toggle).value, isFalse);
    expect(
      find.byKey(const ValueKey('view-manage-categories')),
      findsOneWidget,
    );
  });

  testWidgets('eye menu: viewers see the categories but can\'t toggle', (
    tester,
  ) async {
    await _pump(tester, role: Role.viewer);
    await tester.tap(find.byKey(const ValueKey('fit-menu')));
    await tester.pumpAndSettle();
    final toggle = find.descendant(
      of: find.byKey(ValueKey('view-category-$_rent')),
      matching: find.byType(CheckboxMenuButton),
    );
    expect(tester.widget<CheckboxMenuButton>(toggle).onChanged, isNull);
  });

  for (final (label, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone', Size(390, 844)),
  ]) {
    testWidgets('$label: Events search filters by one or more categories, '
        'with the text search; chips clear; the empty state says so', (
      tester,
    ) async {
      await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      Future<void> pick(String id) async {
        await tester.tap(find.byKey(const ValueKey('filter-categories')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('filter-category-$id')),
            matching: find.byType(CheckboxMenuButton),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('filter-categories')));
        await tester.pumpAndSettle();
      }

      bool row(String id) =>
          find.byKey(ValueKey('dismiss-$id')).evaluate().isNotEmpty ||
          find.byKey(ValueKey('row-delete-$id')).evaluate().isNotEmpty;
      await pick(_groc);
      expect(find.text('Categories · 1'), findsOneWidget);
      expect(
        find.byKey(ValueKey('filter-category-chip-$_groc')),
        findsOneWidget,
      );
      expect(row('g1') && row('g2'), isTrue);
      expect(row('rent') || row('wages'), isFalse);
      await pick(_rent);
      expect(row('rent'), isTrue);
      expect(row('wages'), isFalse);
      // With text: "80" matches only the 80 groceries.
      await tester.enterText(_field('events-search'), '80');
      await tester.pumpAndSettle();
      expect(row('g1'), isTrue);
      expect(row('g2') || row('rent'), isFalse);
      // Nothing matches: the empty state names the categories.
      await tester.enterText(_field('events-search'), 'zzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('events-no-matches')), findsOneWidget);
      expect(find.textContaining('Groceries'), findsWidgets);
      expect(find.textContaining('categories'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('events-clear-filters')));
      await tester.pumpAndSettle();
      expect(row('wages') && row('rent') && row('g1'), isTrue);
      expect(find.byKey(const ValueKey('filter-category-chips')), findsNothing);
      // A chip's ✕ removes one; Clear removes all.
      await pick(_wages);
      await pick(_rent);
      await tester.tap(find.byTooltip('Remove Wages'));
      await tester.pumpAndSettle();
      expect(row('wages'), isFalse);
      expect(row('rent'), isTrue);
      await tester.tap(find.byKey(const ValueKey('filter-categories-clear')));
      await tester.pumpAndSettle();
      expect(row('wages'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plans: the name makes a new category; a taken name is '
      'flagged inline and blocks the commit before any save', (tester) async {
    final store = _Store();
    final events = _EventRepo(store);
    final cats = _Cats(store, events);
    final c = ProviderContainer(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_StreamRepo(store)),
        eventRepositoryProvider.overrideWithValue(events),
        categoryRepositoryProvider.overrideWithValue(cats),
      ],
    );
    addTearDown(c.dispose);
    await c.read(categoriesProvider('acc').future);
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SolveSheet(
                streamId: 'acc',
                initial: const SolveRequest(
                  name: 'Rent',
                  direction: EventDirection.credit,
                  unit: RecurrenceUnit.weeks,
                ),
                creditOnly: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final name = tester.widget<TextField>(_field('plan-name'));
    expect(name.controller!.text, 'Rent 2', reason: 'a free default');
    await tester.enterText(_field('plan-name'), 'groceries');
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('solve-commit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(_field('plan-name'), 'Holiday');
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists'), findsNothing);
  });
}
