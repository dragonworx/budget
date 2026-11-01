// The variables manager (spec 012): roles, the table, in-place edits,
// add, delete, usages and attention, the impact confirm and undo.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/variables/variable_impact.dart';
import 'package:budget_client/features/variables/variables_manager.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'manager_support.dart';

void main() {
  group('roles', () {
    testWidgets('mine: owner description, rows sorted, add row, menus', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      expect(textOf(tester, 'variables-description'), startsWith('Shared by'));
      final ys = [
        for (final id in ['v4', 'v2', 'v1', 'v3']) // months rate rent weeks
          tester.getTopLeft(k('variable-row-$id')).dy,
      ];
      expect(ys, [...ys]..sort());
      expect(k('variable-new-row'), findsOneWidget);
      expect(k('variable-menu-v1'), findsOneWidget);
      expect(textOf(tester, 'variable-value-v1'), r'$1,200.00');
      expect(textOf(tester, 'variable-value-v2'), '5.5%');
      expect(textOf(tester, 'variable-value-v3'), '48');
      expect(textOf(tester, 'variable-expr-v3'), r'$months * 4');
      expect(k('variable-expr-v1'), findsNothing);
      expect(textOf(tester, 'variable-description-v1'), 'Weekly rent');
      expect(h.vars.reads, contains('mine'));
    });

    for (final (role, prefix) in [
      (Role.editor, "The owner's variables"),
      (Role.viewer, 'View only'),
    ]) {
      testWidgets('${role.name}: read-only, no add row or menus', (
        tester,
      ) async {
        final h = await pumpManager(tester, streamId: 's1', role: role);
        expect(textOf(tester, 'variables-description'), startsWith(prefix));
        expect(k('variable-row-v1'), findsOneWidget);
        expect(k('variable-new-row'), findsNothing);
        expect(k('variable-menu-v1'), findsNothing);
        await tester.tap(k('variable-name-v1'));
        await tester.tap(k('variable-value-cell-v1'));
        await tester.pumpAndSettle();
        expect(k('variable-name-field-v1'), findsNothing);
        expect(k('variable-value-field-v1'), findsNothing);
        // Uses still open.
        await tester.tap(k('variable-uses-v1'));
        await tester.pumpAndSettle();
        expect(k('variable-usages'), findsOneWidget);
        expect(h.vars.reads, contains('list s1'));
      });
    }

    testWidgets('owner of a shared stream can edit through it', (tester) async {
      await pumpManager(tester, streamId: 's1');
      expect(k('variable-new-row'), findsOneWidget);
    });

    testWidgets('empty state', (tester) async {
      await pumpManager(tester, vars: const []);
      expect(textOf(tester, 'variables-empty'), startsWith('No variables'));
    });
  });

  group('add', () {
    testWidgets('valid: creates with the unit, clears, keeps focus', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      await enter(tester, 'variable-new-name', 'bonus');
      await tester.tap(k('variable-new-unit'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-new-unit-number').last);
      await tester.pumpAndSettle();
      await enter(tester, 'variable-new-value', '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(h.vars.calls, contains('create bonus=3 number'));
      expect(k('variable-row-n1'), findsOneWidget);
      final name = tester.widget<TextField>(k('variable-new-name'));
      expect(name.controller!.text, '');
      expect(name.focusNode!.hasFocus, isTrue);
      // Closing returns the last created name.
      await tester.tap(k('variables-close'));
      await tester.pumpAndSettle();
      expect(h.result, 'bonus');
    });

    testWidgets('formula value', (tester) async {
      final h = await pumpManager(tester);
      await enter(tester, 'variable-new-name', 'yearly');
      await enter(tester, 'variable-new-value', r'$rent * 52');
      await tester.tap(k('variable-new-add'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, startsWith(r'create yearly=$rent'));
    });

    testWidgets('invalid and duplicate names show inline, no request', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      await enter(tester, 'variable-new-name', '9x');
      expect(
        textOf(tester, 'variable-new-error'),
        'Use letters, digits and _; start with a letter or _',
      );
      await enter(tester, 'variable-new-name', 'RENT');
      expect(textOf(tester, 'variable-new-error'), contains('already exists'));
      await tester.tap(k('variable-new-add'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.where((c) => c.startsWith('create')), isEmpty);
      // A missing value.
      await enter(tester, 'variable-new-name', 'fresh');
      await tester.tap(k('variable-new-add'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'variable-new-error'), 'Enter a value');
    });

    testWidgets('server 409 and cycle errors read well', (tester) async {
      final h = await pumpManager(tester);
      await enter(tester, 'variable-new-name', 'other');
      await enter(tester, 'variable-new-value', '1');
      h.vars.failNext = apiError(409, 'taken', {'code': 'variable_name_taken'});
      await tester.tap(k('variable-new-add'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'variable-new-error'), 'That name is taken');
      h.vars.failNext = apiError(400, r'Circular reference: $a → $b → $a', {
        'code': 'cycle',
        'field': 'expr',
        'path': r'$a → $b → $a',
      });
      await tester.tap(k('variable-new-add'));
      await tester.pumpAndSettle();
      expect(
        textOf(tester, 'variable-new-error'),
        r'These variables depend on each other: $a → $b → $a',
      );
    });

    testWidgets('createName prefills the name and focuses the value', (
      tester,
    ) async {
      await pumpManager(tester, createName: 'gym');
      expect(
        tester.widget<TextField>(k('variable-new-name')).controller!.text,
        'gym',
      );
      final value = find.descendant(
        of: k('variable-new-value'),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(value).focusNode.hasFocus, isTrue);
    });
  });

  group('rename', () {
    testWidgets('tap, Enter saves, undo restores', (tester) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-name-v2'));
      await tester.pumpAndSettle();
      expect(k('variable-name-field-v2'), findsOneWidget);
      await enter(tester, 'variable-name-field-v2', 'interest');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(h.vars.calls, contains('update v2 name=interest'));
      expect(k('variable-name-field-v2'), findsNothing);
      expect(find.text(r'Renamed $rate to $interest'), findsOneWidget);
      await tester.tap(k('variable-undo-button'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v2 name=rate');
      expect(h.vars.store['v2']!.name, 'rate');
      expect(k('variable-undo'), findsNothing);
    });

    testWidgets('Escape cancels without saving and keeps the dialog', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-name-v2'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-name-field-v2', 'nope');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(k('variable-name-field-v2'), findsNothing);
      expect(k('variables-manager'), findsOneWidget);
      expect(h.vars.calls.where((c) => c.startsWith('update')), isEmpty);
      // A second Escape closes the manager.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(k('variables-manager'), findsNothing);
    });

    testWidgets('blur commits; a bad name stays open with the error', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-name-v2'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-name-field-v2', 'rent');
      await tester.tap(k('variable-name-save-v2'));
      await tester.pumpAndSettle();
      expect(find.text(r'A variable named "$rent" already exists'), findsOne);
      expect(k('variable-name-field-v2'), findsOneWidget);
      await enter(tester, 'variable-name-field-v2', 'apr');
      // Focus elsewhere: the add row's name.
      await tester.tap(k('variable-new-name'));
      await tester.pumpAndSettle();
      expect(h.vars.calls, contains('update v2 name=apr'));
      expect(k('variable-name-field-v2'), findsNothing);
    });
  });

  group('value', () {
    testWidgets('unused: saves directly; undo', (tester) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-value-cell-v2'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-value-field-v2', '6');
      await tester.tap(k('variable-value-save-v2'));
      await tester.pumpAndSettle();
      expect(h.vars.calls, isNot(contains(startsWith('preview'))));
      expect(h.vars.calls.last, 'update v2 expr=6');
      expect(textOf(tester, 'variable-value-v2'), '6%');
      await tester.tap(k('variable-undo-button'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v2 expr=5.5');
    });

    testWidgets('used: previews, confirm lists the changes, then saves', (
      tester,
    ) async {
      final h = await pumpManager(tester);
      h.vars.usagesJson['v1'] = {
        'usages': [
          {
            'entity': 'event',
            'entityId': 'e1',
            'streamId': 's1',
            'streamName': 'Everyday',
            'eventName': 'Rent',
            'field': 'amount',
            'expr': r'$rent',
            'value': '1200',
          },
        ],
        'hidden': 0,
      };
      h.vars.previewJson = {
        'changes': [
          {
            'entity': 'event',
            'entityId': 'e1',
            'streamId': 's1',
            'field': 'amount',
            'expr': r'$rent',
            'oldValue': '1200',
            'newValue': '1300',
          },
        ],
        'invalid': 0,
      };
      await tester.tap(k('variable-value-cell-v1'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-value-field-v1', '1300');
      await tester.tap(k('variable-value-save-v1'));
      await tester.pumpAndSettle();
      expect(find.text(r'Update $rent?'), findsOneWidget);
      expect(find.textContaining('Changes 1 field in 1 stream'), findsOne);
      expect(find.textContaining('Rent'), findsWidgets);
      // Cancel: nothing saved, the edit closes.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.vars.calls, isNot(contains('update v1 expr=1300')));
      expect(k('variable-value-field-v1'), findsNothing);
      // Again, confirm.
      await tester.tap(k('variable-value-cell-v1'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-value-field-v1', '1300');
      await tester.tap(k('variable-value-save-v1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v1 expr=1300');
    });

    testWidgets('a broken formula shows the warning, opening fixes it', (
      tester,
    ) async {
      final h = await pumpManager(
        tester,
        vars: [
          ...baseVars(),
          vr(
            'v5',
            'broken',
            r'$gone * 2',
            value: '10',
            problem: {'code': 'unknown_variable', 'message': r'No $gone'},
          ),
        ],
      );
      h.vars.attentionJson = {
        'items': [
          {
            'entity': 'variable',
            'entityId': 'v5',
            'variableName': 'broken',
            'field': 'value',
            'expr': r'$gone * 2',
            'error': {'code': 'unknown_variable', 'message': r'No $gone'},
          },
        ],
        'count': 1,
      };
      ProviderScope.containerOf(tester.element(k('variables-manager')))
          .invalidate(variableAttentionProvider);
      await tester.pumpAndSettle();
      expect(k('variable-problem-v5'), findsOneWidget);
      expect(k('variables-attention'), findsOneWidget);
      await tester.tap(k('variables-attention-show'));
      await tester.pumpAndSettle();
      expect(k('variable-attention-list'), findsOneWidget);
      await tester.tap(k('variable-usage-0'));
      await tester.pumpAndSettle();
      expect(k('variable-value-field-v5'), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('in use: shows where instead', (tester) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-menu-v1'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.text(r'$rent is in use'), findsOneWidget);
      expect(
        textOf(tester, 'variable-usages-message'),
        'Change these fields first, then delete it.',
      );
      expect(h.vars.calls, isNot(contains('delete v1')));
    });

    testWidgets('unused: confirm, delete, undo re-creates', (tester) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-menu-v2'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-delete'));
      await tester.pumpAndSettle();
      expect(find.text(r'Delete $rate?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(h.vars.calls, contains('delete v2'));
      expect(k('variable-row-v2'), findsNothing);
      await tester.tap(k('variable-undo-button'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'create rate=5.5 percent');
      expect(k('variable-row-n1'), findsOneWidget);
    });
  });

  group('menu', () {
    testWidgets('unit, decimals and description', (tester) async {
      final h = await pumpManager(tester);
      await tester.tap(k('variable-menu-v2'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-unit'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-unit-number'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v2 unit=number');

      await tester.tap(k('variable-menu-v1'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-decimals'));
      await tester.pumpAndSettle();
      expect(find.text('2 (default)'), findsOneWidget);
      await tester.tap(k('variable-decimals-0'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v1 decimals=0');
      expect(textOf(tester, 'variable-value-v1'), r'$1,200');

      await tester.tap(k('variable-menu-v1'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-description'));
      await tester.pumpAndSettle();
      await enter(tester, 'variable-description-field', 'Glebe');
      await tester.tap(k('variable-description-save'));
      await tester.pumpAndSettle();
      expect(h.vars.calls.last, 'update v1 description=Glebe');
      expect(textOf(tester, 'variable-description-v1'), 'Glebe');
    });

    testWidgets('number decimals default is "as written"', (tester) async {
      await pumpManager(tester);
      await tester.tap(k('variable-menu-v4'));
      await tester.pumpAndSettle();
      await tester.tap(k('variable-menu-decimals'));
      await tester.pumpAndSettle();
      expect(k('variable-decimals-auto'), findsOneWidget);
      expect(find.text('0 (default)'), findsNothing);
    });
  });

  testWidgets('usages: grouped, hidden count, a variable row jumps', (
    tester,
  ) async {
    final h = await pumpManager(tester);
    h.vars.usagesJson['v4'] = {
      'usages': [
        {
          'entity': 'variable',
          'entityId': 'v3',
          'variableName': 'weeks',
          'field': 'value',
          'expr': r'$months * 4',
          'value': '48',
        },
      ],
      'hidden': 2,
    };
    await tester.tap(k('variable-uses-v4'));
    await tester.pumpAndSettle();
    expect(find.text(r'Where $months is used'), findsOneWidget);
    expect(find.text("+2 in streams you can't see"), findsOneWidget);
    await tester.tap(k('variable-usage-0'));
    await tester.pumpAndSettle();
    expect(k('variable-usages'), findsNothing);
    expect(k('variables-manager'), findsOneWidget);
  });

  testWidgets('live update: the row being edited is deleted elsewhere', (
    tester,
  ) async {
    final h = await pumpManager(tester);
    await tester.tap(k('variable-name-v2'));
    await tester.pumpAndSettle();
    h.vars.store.remove('v2');
    // A realtime refresh.
    final el = tester.element(k('variables-manager'));
    final container = ProviderScope.containerOf(el);
    container.invalidate(myVariablesProvider);
    await tester.pumpAndSettle();
    expect(k('variable-name-field-v2'), findsNothing);
    expect(textOf(tester, 'variables-error'), 'This variable was deleted');
  });

  group('impact text', () {
    test('lists up to 5 changes, the rest and the invalid count', () {
      final changes = [
        for (var i = 0; i < 7; i++)
          {
            'entity': 'event',
            'entityId': 'e$i',
            'streamId': i < 4 ? 's1' : 's2',
            'field': 'amount',
            'oldValue': '1',
            'newValue': '2',
          },
      ];
      final m = impactMessage(usagesFromJson(changes), 2);
      expect(m, startsWith('Changes 7 fields in 2 streams'));
      expect(m, contains('+2 more'));
      expect(
        m,
        contains(
          '2 fields would stop working (they keep their last value until '
          'fixed)',
        ),
      );
    });
  });

  test('display decimals: money 2, others as written', () {
    expect(defaultVariableDecimals('money'), 2);
    expect(defaultVariableDecimals('percent'), isNull);
    expect(defaultVariableDecimals('number'), isNull);
  });
}
