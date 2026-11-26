import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/category_totals.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEvent _event(
  String id, {
  String? categoryId,
  String name = '',
  bool enabled = true,
  bool categoryHidden = false,
  String streamId = 's',
}) => BudgetEvent(
  id: id,
  streamId: streamId,
  name: name.isEmpty ? id : name,
  direction: EventDirection.debit,
  amount: Decimal.fromInt(1),
  startDate: DateTime(2026, 1, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  enabled: enabled,
  categoryId: categoryId,
  categoryHidden: categoryHidden,
);

Category _cat(String id, String name, String color, {String? parentId}) =>
    Category(
      id: id,
      streamId: 's',
      name: name,
      color: color,
      parentId: parentId,
    );

Occurrence _o(
  String eventId,
  DateTime date,
  int cents, {
  bool skipped = false,
  bool netted = false,
  String? component,
  bool derived = false,
}) => Occurrence(
  eventId: eventId,
  date: date,
  signedDelta: Decimal.fromInt(cents).shift(-2),
  skipped: skipped,
  netted: netted,
  component: component,
  derived: derived,
);

void main() {
  final groc = _cat('groc', 'Groceries', '#4CAF50');
  final rent = _cat('rent', 'Rent', '#2196F3');
  final sal = _cat('sal', 'Salary', '#FFC107');
  final cats = [groc, rent, sal];

  final grocery = _event('g', categoryId: 'groc', name: 'Groceries');
  final rentEv = _event('r', categoryId: 'rent', name: 'Rent');
  final salary = _event('s', categoryId: 'sal', name: 'Salary');
  final events = {
    for (final e in [grocery, rentEv, salary]) e.id: e,
  };

  test('in/out split and two events in one category merge', () {
    final otherGrocery = _event('g2', categoryId: 'groc', name: 'Market');
    final totals = summarizeCategories(
      occurrences: [
        _o('g', DateTime(2026, 11, 2), -4000),
        _o('g2', DateTime(2026, 11, 3), -2000),
        _o('s', DateTime(2026, 11, 1), 10000),
        _o('r', DateTime(2026, 11, 5), -3000),
      ],
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 30),
      events: {...events, 'g2': otherGrocery},
      categories: cats,
    );
    expect(totals.inCents, 10000);
    expect(totals.outCents, -9000);
    expect(totals.netCents, 1000);
    final grocB = totals.buckets.singleWhere((b) => b.id == 'groc');
    expect(grocB.outCents, -6000);
    expect(grocB.count, 2);
    expect(grocB.color, const Color(0xFF4CAF50));
    expect(totals.buckets.where((b) => b.id == 'groc'), hasLength(1));
  });

  test('transfers count, netted transfers do not', () {
    final xfer = _event('x', categoryId: 'groc', name: 'Transfer');
    final totals = summarizeCategories(
      occurrences: [
        _o('x', DateTime(2026, 11, 2), -1500),
        _o('x', DateTime(2026, 11, 3), -1500, netted: true),
      ],
      start: null,
      end: null,
      events: {'x': xfer},
      categories: cats,
    );
    expect(totals.outCents, -1500);
    expect(totals.buckets.single.count, 1);
  });

  test('skipped and inactive / hidden-category events are omitted', () {
    final off = _event('off', categoryId: 'groc', enabled: false);
    final hidden = _event('hid', categoryId: 'rent', categoryHidden: true);
    final totals = summarizeCategories(
      occurrences: [
        _o('g', DateTime(2026, 11, 2), -100, skipped: true),
        _o('off', DateTime(2026, 11, 2), -200),
        _o('hid', DateTime(2026, 11, 2), -300),
        _o('g', DateTime(2026, 11, 2), -400),
      ],
      start: null,
      end: null,
      events: {...events, 'off': off, 'hid': hidden},
      categories: cats,
    );
    expect(totals.outCents, -400);
    expect(totals.buckets, hasLength(1));
  });

  test('Sync pins and drift are omitted', () {
    final sync = _event('pin', categoryId: 'sal', name: 'Sync');
    final totals = summarizeCategories(
      occurrences: [
        _o('pin', DateTime(2026, 11, 2), 500, component: 'sync'),
        _o('s', DateTime(2026, 11, 2), 1000),
      ],
      start: null,
      end: null,
      events: {...events, 'pin': sync},
      categories: cats,
    );
    expect(totals.inCents, 1000);
    expect(totals.buckets.single.id, 'sal');
  });

  test('interest is the Loan interest bucket', () {
    final loan = _event('loan', categoryId: 'rent', name: 'Mortgage');
    final totals = summarizeCategories(
      occurrences: [
        _o('loan', DateTime(2026, 11, 2), -800, component: 'interest'),
        _o('loan', DateTime(2026, 11, 3), -200, derived: true),
        _o('loan', DateTime(2026, 11, 4), -5000),
      ],
      start: null,
      end: null,
      events: {'loan': loan},
      categories: cats,
    );
    final interest = totals.buckets.singleWhere(
      (b) => b.id == interestBucketId,
    );
    expect(interest.name, 'Loan interest');
    expect(interest.outCents, -1000);
    expect(interest.count, 2);
    final rentB = totals.buckets.singleWhere((b) => b.id == 'rent');
    expect(rentB.outCents, -5000);
  });

  test('Uncategorised', () {
    final loose = _event('loose', categoryId: null, name: 'Mystery');
    final totals = summarizeCategories(
      occurrences: [_o('loose', DateTime(2026, 11, 2), -250)],
      start: null,
      end: null,
      events: {'loose': loose},
      categories: cats,
    );
    expect(totals.buckets, hasLength(1));
    expect(totals.buckets.single.id, uncategorisedBucketId);
    expect(totals.buckets.single.name, 'Uncategorised');
    expect(totals.outCents, -250);
  });

  test(
    'range start/end inclusive; All time uses every supplied occurrence',
    () {
      final occ = [
        _o('g', DateTime(2026, 10, 31), -10),
        _o('g', DateTime(2026, 11, 1), -20),
        _o('g', DateTime(2026, 11, 30), -30),
        _o('g', DateTime(2026, 12, 1), -40),
      ];
      final ranged = summarizeCategories(
        occurrences: occ,
        start: DateTime(2026, 11, 1),
        end: DateTime(2026, 11, 30),
        events: events,
        categories: cats,
      );
      expect(ranged.outCents, -50);
      final all = summarizeCategories(
        occurrences: occ,
        start: null,
        end: null,
        events: events,
        categories: cats,
      );
      expect(all.outCents, -100);
    },
  );

  test('Other at 2% and at the 9th category', () {
    // Total 10000 out. 199 is < 2%; 200 is 2% and kept.
    Category catN(int i) => _cat('c$i', 'Cat $i', '#808080');
    BudgetEvent ev(int i) => _event('e$i', categoryId: 'c$i', name: 'Cat $i');
    final twoPct = summarizeCategories(
      occurrences: [
        _o('e0', DateTime(2026, 11, 1), -9801),
        _o('e1', DateTime(2026, 11, 1), -199),
      ],
      start: null,
      end: null,
      events: {'e0': ev(0), 'e1': ev(1)},
      categories: [catN(0), catN(1)],
    );
    final side = twoPct.side(moneyOut: true);
    expect(side.map((b) => b.id).toList(), ['c0', otherBucketId]);
    expect(side.last.outCents, -199);
    expect(side.last.groupedCount, 1);

    final exact = summarizeCategories(
      occurrences: [
        _o('e0', DateTime(2026, 11, 1), -9800),
        _o('e1', DateTime(2026, 11, 1), -200),
      ],
      start: null,
      end: null,
      events: {'e0': ev(0), 'e1': ev(1)},
      categories: [catN(0), catN(1)],
    );
    expect(exact.side(moneyOut: true).map((b) => b.id).toList(), ['c0', 'c1']);

    // 9 categories all well over 2%: first 8 kept, 9th → Other.
    final occ9 = [
      for (var i = 0; i < 9; i++) _o('e$i', DateTime(2026, 11, 1), -1000 - i),
    ];
    final nine = summarizeCategories(
      occurrences: occ9,
      start: null,
      end: null,
      events: {for (var i = 0; i < 9; i++) 'e$i': ev(i)},
      categories: [for (var i = 0; i < 9; i++) catN(i)],
    );
    final s9 = nine.side(moneyOut: true);
    expect(s9, hasLength(9)); // 8 + Other
    expect(s9.last.id, otherBucketId);
    expect(s9.last.groupedCount, 1);
    // Largest first: e8 has 1008, then e7 1007, ... e1 1001 kept; e0 1000 → Other
    expect(s9.first.id, 'c8');
    expect(s9[7].id, 'c1');
    expect(s9.last.outCents, -1000);
  });

  test('empty range and both sides zero', () {
    final empty = summarizeCategories(
      occurrences: const [],
      start: DateTime(2026, 11, 1),
      end: DateTime(2026, 11, 30),
      events: events,
      categories: cats,
    );
    expect(empty.isEmpty, isTrue);
    expect(empty.inCents, 0);
    expect(empty.outCents, 0);
    expect(empty.side(moneyOut: true), isEmpty);
    expect(empty.side(moneyOut: false), isEmpty);
  });

  test('combined streams', () {
    final other = _event(
      'og',
      categoryId: 'groc',
      name: 'Other groc',
      streamId: 'b',
    );
    final totals = summarizeCategories(
      occurrences: [
        _o('g', DateTime(2026, 11, 2), -100),
        _o('og', DateTime(2026, 11, 2), -50),
      ],
      start: null,
      end: null,
      events: {...events, 'og': other},
      categories: cats,
    );
    expect(totals.outCents, -150);
    expect(totals.buckets.singleWhere((b) => b.id == 'groc').count, 2);
  });

  test('zero-amount slice is omitted from a side', () {
    final totals = summarizeCategories(
      occurrences: [
        _o('s', DateTime(2026, 11, 1), 5000),
        _o('g', DateTime(2026, 11, 2), -100),
      ],
      start: null,
      end: null,
      events: events,
      categories: cats,
    );
    expect(totals.side(moneyOut: false).map((b) => b.id), ['sal']);
    expect(totals.side(moneyOut: true).map((b) => b.id), ['groc']);
  });
}
