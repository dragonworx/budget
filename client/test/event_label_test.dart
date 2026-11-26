// Optional event/transaction label: display title, lane text, list row,
// and the editor field under Category (no autofocus, no keyboard primer).
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/timeline/stack_lanes.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';
import 'support/fake_loans.dart';
import 'support/fake_streams.dart';

BudgetEvent ev(
  String name, {
  String? label,
  EventDirection dir = EventDirection.debit,
  TransferLink? transfer,
}) => BudgetEvent(
  id: name.toLowerCase(),
  streamId: 'a',
  name: name,
  label: label,
  direction: dir,
  amount: Decimal.fromInt(10),
  startDate: DateTime(2026, 11, 1),
  recurrenceMode: RecurrenceMode.once,
  endMode: EndMode.never,
  enabled: true,
  transfer: transfer,
);

void main() {
  test('eventTitle is the category, plus ": label" when set', () {
    expect(eventTitle(ev('Salary')), 'Salary');
    expect(eventTitle(ev('Salary', label: 'Bonus')), 'Salary: Bonus');
    expect(eventTitle(ev('  Salary  ', label: '  Bonus  ')), 'Salary: Bonus');
    expect(eventTitle(ev('', label: 'Bonus')), 'Bonus');
    expect(eventTitle(ev(''), empty: 'Untitled'), 'Untitled');
    expect(eventTitle(ev('', label: 'Bonus'), empty: 'Untitled'), 'Untitled: Bonus');
    expect(eventTitle(ev('Salary', label: '')), 'Salary');
    expect(eventTitle(ev('Salary', label: '   ')), 'Salary');
  });

  test('eventLabel keeps the transfer phrase; label sits after the name', () {
    expect(eventLabel(ev('Salary')), 'Salary');
    expect(eventLabel(ev('Salary', label: 'Bonus')), 'Salary: Bonus');
    final t = ev(
      'Save',
      transfer: const TransferLink(
        id: 'x',
        peerEventId: 't2',
        peerStreamId: 'b',
        peerStreamName: 'Ops',
      ),
    );
    expect(eventLabel(t), 'Save · To: Ops');
    expect(eventLabel(t.copyWith(label: 'Bonus')), 'Save: Bonus · To: Ops');
    expect(eventLabel(t.copyWith(name: '', label: 'Bonus')), 'Bonus · To: Ops');
  });

  test('JSON reads and writes label; empty becomes null', () {
    final t = ev('Salary', label: 'Bonus');
    expect(t.toJson()['label'], 'Bonus');
    expect(t.toCreateJson()['label'], 'Bonus');
    expect(BudgetEvent.fromJson(t.toJson()).label, 'Bonus');
    expect(BudgetEvent.fromJson({...t.toJson(), 'label': '  '}).label, isNull);
    expect(ev('Salary').toCreateJson()['label'], isNull);
    expect(t.copyWith(clearLabel: true).label, isNull);
    expect(t.copyWith(name: 'Pay').label, 'Bonus');
  });

  test('a lane shows "Category: Label", or just the category', () {
    final set = buildLaneSet(
      order: const ['salary', 'rent'],
      events: {
        'salary': ev('Salary', label: 'Bonus', dir: EventDirection.credit),
        'rent': ev('Rent'),
      },
    );
    expect(set.lanes.map((l) => l.label).toList(), ['Salary: Bonus', 'Rent']);
    final empty = buildLaneSet(order: const ['x'], events: {'x': ev('')});
    expect(empty.lanes.single.label, 'Event');
  });

  testWidgets(
    'Label sits under Category; existing editors do not autofocus it',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final existing = ev('Salary', label: 'Bonus', dir: EventDirection.credit);
      final streams = FakeLoanStreamRepository(
        streams: [testStream('acc', 'Everyday')],
      );
      final events = FakeLoanEventRepository({
        'acc': [existing],
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            streamRepositoryProvider.overrideWithValue(streams),
            eventRepositoryProvider.overrideWithValue(events),
            categoryRepositoryProvider.overrideWith(
              (ref) => FakeCategoryRepository(events, ['Salary']),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: EventEditor(
                streamId: 'acc',
                existing: existing,
                initialDate: DateTime(2026, 11, 1),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final category = tester.getRect(
        find.byKey(const ValueKey('editor-category')),
      );
      final label = tester.getRect(find.byKey(const ValueKey('editor-label')));
      expect(label.top, greaterThan(category.bottom - 1));
      expect(find.text('Label'), findsOneWidget);
      expect(find.text('Optional detail'), findsOneWidget);
      expect(find.text('Bonus'), findsOneWidget);

      final focused = testersFocused(tester);
      expect(focused, isNot(equals('editor-label')), reason: '$focused');
      expect(focused, isNot(equals('editor-amount')), reason: '$focused');
    },
  );
}

String? testersFocused(WidgetTester tester) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  if (ctx.widget.key case final ValueKey key) return key.value?.toString();
  String? found;
  ctx.visitAncestorElements((el) {
    if (el.widget.key case final ValueKey key) {
      found = key.value?.toString();
      return false;
    }
    return true;
  });
  return found;
}
