// Hierarchical categories: tree helpers, last-used default (hidden /
// deleted fallback), and breakdown roll-up with a Direct line.
import 'package:budget_client/boot/page_stub.dart';
import 'package:budget_client/data/category_tree.dart';
import 'package:budget_client/data/last_category.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_types.dart';
import 'package:budget_client/features/timeline/group_breakdown_sheet.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

Category _c(
  String id,
  String name, {
  String? parentId,
  bool hidden = false,
  int eventCount = 0,
  int eventCountSubtree = 0,
  int sortOrder = 0,
}) => Category(
  id: id,
  streamId: 's',
  name: name,
  color: '#3D6FD8',
  parentId: parentId,
  hidden: hidden,
  eventCount: eventCount,
  eventCountSubtree: eventCountSubtree,
  sortOrder: sortOrder,
  depth: parentId == null ? 0 : 1,
);

BudgetEvent _ev(String id, String categoryId) => BudgetEvent(
  id: id,
  streamId: 's',
  name: categoryId,
  categoryId: categoryId,
  direction: EventDirection.debit,
  amount: Decimal.fromInt(10),
  startDate: DateTime(2026, 1, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
);

void main() {
  setUp(clearLocal);

  test(
    'tree: path, flatten, hidden parent hides the branch, Sync never nests',
    () {
      final all = [
        _c('u', 'Utilities', sortOrder: 0),
        _c('p', 'Power', parentId: 'u', sortOrder: 0),
        _c('g', 'Gas', parentId: 'u', sortOrder: 1),
        _c('ins', 'Insurance', sortOrder: 1),
        _c('hid', 'Shopping', hidden: true, sortOrder: 2),
        _c('coles', 'Coles', parentId: 'hid', sortOrder: 0),
      ];
      expect(categoryPathLabel(all, 'p'), 'Utilities › Power');
      expect(flattenedTree(all).map((c) => c.id).toList(), [
        'u',
        'p',
        'g',
        'ins',
        'hid',
        'coles',
      ]);
      expect(
        hiddenInPicker(all, all.firstWhere((c) => c.id == 'coles')),
        isTrue,
      );
      expect(hiddenInPicker(all, all.firstWhere((c) => c.id == 'p')), isFalse);
      expect(visibleForPicker(all).map((c) => c.id).toList(), [
        'u',
        'p',
        'g',
        'ins',
      ]);
      expect(
        canNestUnder(
          all,
          all.firstWhere((c) => c.id == 'p'),
          all.firstWhere((c) => c.id == 'ins'),
        ),
        isTrue,
      );
      expect(
        canNestUnder(
          all,
          all.firstWhere((c) => c.id == 'u'),
          all.firstWhere((c) => c.id == 'ins'),
        ),
        isFalse,
        reason: 'a parent with children stays top-level',
      );
      expect(
        canNestUnder(
          all,
          all.firstWhere((c) => c.id == 'ins'),
          _c('sync', 'Sync'),
        ),
        isFalse,
      );
      expect(isSyncCategoryName(' sync '), isTrue);
    },
  );

  test('last category persists and skips hidden or deleted', () {
    storeLastCategory('s', 'gone', userId: 'u');
    expect(readStoredLastCategory('s', userId: 'u'), 'gone');

    final cats = [
      _c('u', 'Utilities'),
      _c('p', 'Power', parentId: 'u'),
      _c('hid', 'Secret', hidden: true),
    ];
    expect(
      defaultNewEventCategory(categories: cats, preferredId: 'gone')?.id,
      'u',
      reason: 'deleted id falls back to first visible',
    );
    expect(
      defaultNewEventCategory(categories: cats, preferredId: 'hid')?.id,
      'u',
      reason: 'hidden preferred is skipped',
    );
    expect(
      defaultNewEventCategory(categories: cats, preferredId: 'p')?.id,
      'p',
    );

    final power = BudgetEvent(
      id: 'e1',
      streamId: 's',
      name: 'Power',
      categoryId: 'p',
      direction: EventDirection.debit,
      amount: Decimal.fromInt(10),
      startDate: DateTime(2026, 1, 1),
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
    );
    final gone = BudgetEvent(
      id: 'e0',
      streamId: 's',
      name: 'Old',
      categoryId: 'gone',
      direction: EventDirection.debit,
      amount: Decimal.fromInt(10),
      startDate: DateTime(2026, 1, 2),
      recurrenceMode: RecurrenceMode.once,
      endMode: EndMode.never,
    );
    expect(
      defaultNewEventCategory(
        categories: cats,
        preferredId: 'gone',
        recentEvents: [power, gone],
      )?.id,
      'p',
      reason:
          'stored gone: use previous visible transaction, skip the deleted one',
    );
    expect(
      defaultNewEventCategory(
        categories: cats,
        preferredId: null,
        recentEvents: [power],
      )?.id,
      'p',
      reason: 'no stored last category: previous transaction',
    );
  });

  test('breakdown rolls children under the parent with a Direct line', () {
    final cats = [
      _c('u', 'Utilities'),
      _c('p', 'Power', parentId: 'u'),
      _c('g', 'Gas', parentId: 'u'),
      _c('ins', 'Insurance'),
    ];
    const lines = <BreakdownLine>[
      (name: 'Power', count: 2, cents: -4000),
      (name: 'Utilities', count: 1, cents: -1000),
      (name: 'Gas', count: 1, cents: -2000),
      (name: 'Insurance', count: 1, cents: -5000),
    ];
    final rolled = rollUpBreakdownLines(lines, cats);
    expect(rolled.map((n) => n.name).toList(), ['Utilities', 'Insurance']);
    expect(rolled.first.count, 4);
    expect(rolled.first.cents, -7000);
    expect(rolled.first.children.map((c) => c.name).toList(), [
      'Direct',
      'Power',
      'Gas',
    ]);
    expect(rolled.first.children.first.isDirect, isTrue);
    expect(rolled.first.children.first.cents, -1000);
    expect(rolled.last.children, isEmpty);
    expect(rolled.last.cents, -5000);
    // Parent total is direct + children.
    expect(
      rolled.first.cents,
      rolled.first.children.fold<int>(0, (a, c) => a + c.cents),
    );
  });
}
