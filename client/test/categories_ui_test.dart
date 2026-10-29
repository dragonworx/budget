// Categories (global per owner): the model helpers, the manager table
// (in-place rename, swatch, count, Delete N events / Delete category, the
// dashed new-category row; opened from the header ⋮), the editor's read-only
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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
    final c = (await list(streamId)).where((c) => c.id == id).firstOrNull;
    final gone = [
      for (final e in s.txs.values)
        if (e.categoryId == id) e.id,
    ];
    gone.forEach(s.txs.remove);
    // Keep the (now empty) category listed.
    calls.add('deleteEvents $id');
    if (c != null) {
      (extra[streamId] ??= []).add(
        Category(id: c.id, streamId: c.streamId, name: c.name, color: c.color),
      );
    }
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
  await tester.tap(find.byKey(const ValueKey('timeline-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('more-categories')));
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
    ('phone 320', Size(320, 640)),
  ]) {
    testWidgets('$label: the manager is a table (colour, name, count, two '
        'action buttons) with a dashed new-category row last; no overflow', (
      tester,
    ) async {
      await _pump(tester, size: size);
      await _openManager(tester);
      expect(find.byKey(const ValueKey('categories-table')), findsOneWidget);
      expect(find.text('NAME'), findsOneWidget);
      expect(find.text('EVENTS'), findsOneWidget);
      final dialog = tester.getRect(
        find.byKey(const ValueKey('categories-manager')),
      );
      for (final (id, n) in [(_wages, 1), (_rent, 1), (_groc, 2)]) {
        final row = find.byKey(ValueKey('category-row-$id'));
        expect(row, findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(ValueKey('category-count-$id'))).data,
          '$n',
        );
        for (final k in [
          'category-color-$id',
          'category-name-$id',
          'category-delete-events-$id',
          'category-delete-$id',
        ]) {
          final r = tester.getRect(find.byKey(ValueKey(k)));
          expect(r.right, lessThanOrEqualTo(dialog.right + 0.5), reason: k);
        }
        // Actions sit on the right, after the count, with tooltips.
        expect(
          tester.getRect(find.byKey(ValueKey('category-delete-$id'))).left,
          greaterThan(
            tester.getRect(find.byKey(ValueKey('category-count-$id'))).right,
          ),
        );
        final del = tester.widget<IconButton>(
          find.byKey(ValueKey('category-delete-$id')),
        );
        expect(del.tooltip, contains('Delete category'));
        // Usable touch targets.
        expect(
          tester.getSize(find.byKey(ValueKey('category-delete-$id'))).width,
          greaterThanOrEqualTo(36),
        );
      }
      expect(find.byKey(const ValueKey('category-new-row')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('category-new-row'))).top,
        greaterThan(
          tester.getRect(find.byKey(ValueKey('category-row-$_groc'))).bottom,
        ),
      );
      expect(find.byType(Scrollable).evaluate().length, greaterThan(0));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is MenuAnchor &&
              w.key is ValueKey &&
              (w.key! as ValueKey).value.toString().startsWith(
                'category-menu-',
              ),
        ),
        findsNothing,
        reason: 'no ⋮ menus any more',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the header ⋮ has "Edit categories"; the Events list has no '
      'categories button', (tester) async {
    await _pump(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('open-events')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-categories')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('panel-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline-more')));
    await tester.pumpAndSettle();
    expect(find.text('Edit categories'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('categories-manager')), findsOneWidget);
    expect(find.textContaining('all your streams'), findsWidgets);
  });

  testWidgets('a name is renamed in place: tap, type, Enter / check / blur '
      'commit, Escape cancels, a duplicate is rejected inline', (tester) async {
    final (_, cats) = await _pump(tester);
    await _openManager(tester);
    Future<void> edit() async {
      await tester.tap(find.byKey(ValueKey('category-name-$_rent')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('category-name-field-$_rent')),
        findsOneWidget,
      );
    }

    // Escape cancels.
    await edit();
    await tester.enterText(_field('category-name-field-$_rent'), 'Nope');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('category-name-field-$_rent')), findsNothing);
    expect(cats.calls.where((c) => c.startsWith('update')), isEmpty);
    expect(find.byKey(const ValueKey('categories-manager')), findsOneWidget);

    // A duplicate (any case) shows an error and saves nothing.
    await edit();
    await tester.enterText(_field('category-name-field-$_rent'), ' wages ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('already exists'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('category-name-save-$_rent')));
    await tester.pumpAndSettle();
    expect(cats.calls.where((c) => c.startsWith('update')), isEmpty);
    expect(find.byKey(ValueKey('category-name-field-$_rent')), findsOneWidget);

    // Enter commits.
    await tester.enterText(_field('category-name-field-$_rent'), 'Housing');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(cats.calls, contains(startsWith('update $_rent Housing')));
    expect(find.byKey(ValueKey('category-name-field-$_rent')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(ValueKey('category-name-$_rent')),
        matching: find.text('Housing'),
      ),
      findsOneWidget,
    );

    // The check button commits.
    await tester.tap(find.byKey(ValueKey('category-name-$_groc')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('category-name-field-$_groc'), 'Food');
    await tester.tap(find.byKey(ValueKey('category-name-save-$_groc')));
    await tester.pumpAndSettle();
    expect(cats.calls, contains(startsWith('update $_groc Food')));

    // Blur (tapping elsewhere) commits.
    await tester.tap(find.byKey(ValueKey('category-name-$_wages')));
    await tester.pumpAndSettle();
    await tester.enterText(_field('category-name-field-$_wages'), 'Salary');
    await tester.tap(find.byKey(const ValueKey('categories-description')));
    await tester.pumpAndSettle();
    expect(cats.calls, contains(startsWith('update $_wages Salary')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the swatch recolours from the palette', (tester) async {
    final (_, cats) = await _pump(tester);
    await _openManager(tester);
    await tester.tap(find.byKey(ValueKey('category-color-$_rent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-swatch-5')));
    await tester.pumpAndSettle();
    expect(
      cats.calls,
      contains('update $_rent  ${colorToHex(laneColors[5])} '),
    );
  });

  testWidgets('the last row creates: add is disabled until the name is '
      'valid and unique; Enter creates; colour defaults random, changeable', (
    tester,
  ) async {
    categoryColorRandom = math.Random(1);
    addTearDown(() => categoryColorRandom = null);
    final (_, cats) = await _pump(tester, size: const Size(390, 844));
    await _openManager(tester);
    IconButton add() => tester.widget<IconButton>(
      find.byKey(const ValueKey('category-new-save')),
    );
    expect(add().onPressed, isNull, reason: 'empty');
    await tester.enterText(_field('category-new-name'), ' rent ');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-new-error')), findsOneWidget);
    expect(add().onPressed, isNull, reason: 'taken');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(cats.calls.where((c) => c.startsWith('create')), isEmpty);
    await tester.enterText(_field('category-new-name'), 'Fuel');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('category-new-error')), findsNothing);
    expect(add().onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('category-new-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-swatch-7')));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(cats.calls, contains('create Fuel'));
    final fuel = fakeCategoryId('Fuel');
    expect(find.byKey(ValueKey('category-row-$fuel')), findsOneWidget);
    expect(
      (cats.extra['acc'] ?? []).firstWhere((c) => c.id == fuel).color,
      colorToHex(laneColors[7]),
    );
    // Cleared for the next one; the add button tap works too.
    expect(
      tester.widget<TextField>(_field('category-new-name')).controller!.text,
      '',
    );
    await tester.enterText(_field('category-new-name'), 'Gym');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('category-new-save')));
    await tester.pumpAndSettle();
    expect(cats.calls, contains('create Gym'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Delete N events confirms (all streams), keeps the category, '
      'the count updates live, the button disables at 0, and Undo restores', (
    tester,
  ) async {
    final (store, cats) = await _pump(tester);
    await _openManager(tester);
    final btn = find.byKey(ValueKey('category-delete-events-$_groc'));
    expect(
      tester.widget<IconButton>(btn).tooltip,
      'Delete 2 events in all streams (keep category)',
    );
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 events?'), findsOneWidget);
    expect(find.textContaining('across all your streams'), findsOneWidget);
    expect(find.textContaining('The category stays.'), findsOneWidget);
    await tester.tap(find.text('Delete 2 events').last);
    await tester.pumpAndSettle();
    expect(cats.calls, contains('deleteEvents $_groc'));
    expect(store.txs.keys, isNot(contains('g1')));
    expect(find.byKey(ValueKey('category-row-$_groc')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(ValueKey('category-count-$_groc'))).data,
      '0',
    );
    expect(tester.widget<IconButton>(btn).onPressed, isNull);
    expect(find.byKey(const ValueKey('category-undo')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('category-undo-button')));
    await tester.pumpAndSettle();
    expect(store.calls, contains('undo batch-$_groc'));
    expect(store.txs.keys, containsAll(['g1', 'g2']));
    expect(
      tester.widget<Text>(find.byKey(ValueKey('category-count-$_groc'))).data,
      '2',
    );
  });

  testWidgets('Delete category: the confirmation names it and its event '
      'count in all streams; Cancel keeps it, confirming deletes both', (
    tester,
  ) async {
    final (store, cats) = await _pump(tester);
    await _openManager(tester);
    await tester.tap(find.byKey(ValueKey('category-delete-$_groc')));
    await tester.pumpAndSettle();
    expect(find.text('Delete category "Groceries"?'), findsOneWidget);
    expect(
      find.textContaining('all 2 of its events across all your streams'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(cats.calls.where((c) => c.startsWith('delete')), isEmpty);
    await tester.tap(find.byKey(ValueKey('category-delete-$_groc')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete category and events'));
    await tester.pumpAndSettle();
    expect(cats.calls, contains('delete $_groc'));
    expect(store.txs.keys, isNot(contains('g2')));
    expect(find.byKey(ValueKey('category-row-$_groc')), findsNothing);
  });

  testWidgets('viewers: the table is read-only (no actions, no rename, no '
      'new row)', (tester) async {
    await _pump(tester, role: Role.viewer);
    await _openManager(tester);
    expect(find.byKey(ValueKey('category-row-$_rent')), findsOneWidget);
    expect(find.byKey(ValueKey('category-delete-$_rent')), findsNothing);
    expect(find.byKey(ValueKey('category-delete-events-$_rent')), findsNothing);
    expect(find.byKey(ValueKey('category-color-$_rent')), findsNothing);
    expect(find.byKey(const ValueKey('category-new-row')), findsNothing);
    await tester.tap(find.byKey(ValueKey('category-name-$_rent')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('category-name-field-$_rent')), findsNothing);
  });

  testWidgets('editors: may add on the last row, but not rename or delete '
      '(those reach all the owner\'s streams)', (tester) async {
    await _pump(tester, role: Role.editor);
    await _openManager(tester);
    expect(find.byKey(const ValueKey('category-new-row')), findsOneWidget);
    expect(find.byKey(ValueKey('category-delete-$_rent')), findsNothing);
    expect(find.byKey(ValueKey('category-color-$_rent')), findsNothing);
    expect(find.textContaining('only the owner'), findsOneWidget);
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
    testWidgets('$label: a full-width category dropdown (no text search) '
        'filters the list; All categories clears; the empty state says so', (
      tester,
    ) async {
      await _pump(tester, size: size);
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('events-search')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('events-panel-body')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      final dd = find.byKey(const ValueKey('events-category-filter'));
      expect(dd, findsOneWidget);
      expect(find.text('All categories'), findsOneWidget);
      // Full width: as wide as the filter chips' row allows (the panel
      // minus its 20px gutters).
      final panel = tester.getRect(
        find.byKey(const ValueKey('events-panel-body')),
      );
      expect(tester.getSize(dd).width, closeTo(panel.width - 40, 1));
      Future<void> pick(String key) async {
        await tester.tap(dd);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)).last);
        await tester.pumpAndSettle();
      }

      bool row(String id) =>
          find.byKey(ValueKey('dismiss-$id')).evaluate().isNotEmpty ||
          find.byKey(ValueKey('row-delete-$id')).evaluate().isNotEmpty;
      // The open menu: All categories plus each category with its dot.
      await tester.tap(dd);
      await tester.pumpAndSettle();
      for (final id in [_wages, _rent, _groc]) {
        expect(find.byKey(ValueKey('filter-category-$id')), findsWidgets);
      }
      await tester.tap(find.byKey(ValueKey('filter-category-$_groc')).last);
      await tester.pumpAndSettle();
      expect(row('g1') && row('g2'), isTrue);
      expect(row('rent') || row('wages'), isFalse);
      // One at a time: choosing Rent replaces Groceries.
      await pick('filter-category-$_rent');
      expect(row('rent'), isTrue);
      expect(row('g1') || row('wages'), isFalse);
      // With the direction filter: nothing matches; the empty state names
      // the category and Clear filters resets both.
      await tester.tap(find.byKey(const ValueKey('filter-credit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('events-no-matches')), findsOneWidget);
      expect(find.textContaining('category Rent'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('events-clear-filters')));
      await tester.pumpAndSettle();
      expect(row('wages') && row('rent') && row('g1'), isTrue);
      expect(find.text('All categories'), findsOneWidget);
      // All categories clears a selection.
      await pick('filter-category-$_wages');
      expect(row('rent'), isFalse);
      await pick('filter-category-all');
      expect(row('wages') && row('rent') && row('g1'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (label, size) in const [
    ('desktop', Size(1440, 900)),
    ('phone 390', Size(390, 844)),
    ('phone 320', Size(320, 640)),
  ]) {
    testWidgets('$label: every type label is fully visible (also with '
        'Transfer selected), at full text size', (tester) async {
      await _pump(tester, size: size);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-events')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('panel-new-event')));
      await tester.pumpAndSettle();
      void check() {
        final kind = tester.getRect(find.byKey(const ValueKey('editor-kind')));
        for (final t in ['Money in', 'Money out', 'Transfer']) {
          final f = find.descendant(
            of: find.byKey(const ValueKey('editor-kind')),
            matching: find.text(t),
          );
          final p = tester.renderObject<RenderParagraph>(f);
          expect(
            p.textSize.width,
            lessThanOrEqualTo(p.size.width + 0.5),
            reason: '$t is cut',
          );
          final r = tester.getRect(f);
          expect(r.left, greaterThanOrEqualTo(kind.left));
          expect(r.right, lessThanOrEqualTo(kind.right));
        }
        expect(tester.takeException(), isNull);
      }

      check();
      await tester.tap(find.byKey(const ValueKey('editor-kind-transfer')));
      await tester.pumpAndSettle();
      check();
    });
  }

  testWidgets('confirmations are singular for one event, plural for more '
      '(never "all 1 event")', (tester) async {
    await _pump(tester);
    await _openManager(tester);
    // Rent has 1 event.
    await tester.tap(find.byKey(ValueKey('category-delete-$_rent')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('"Rent" and its 1 event across all your streams.'),
      findsOneWidget,
    );
    expect(find.textContaining('all 1'), findsNothing);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('category-delete-events-$_rent')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 event?'), findsOneWidget);
    expect(
      find.textContaining(
        'The 1 event in "Rent" is deleted across all your streams.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('All 1'), findsNothing);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    // Groceries has 2.
    await tester.tap(find.byKey(ValueKey('category-delete-events-$_groc')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'All 2 events in "Groceries" are deleted across all your streams.',
      ),
      findsOneWidget,
    );
  });

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
