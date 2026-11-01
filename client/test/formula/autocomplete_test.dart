// `$` autocomplete (spec 011 item 9).
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:budget_client/widgets/formula/formula_field.dart';

import 'formula_support.dart';

List<String> shown(WidgetTester tester) => [
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith(
                  'formula-suggestion-',
                ),
          )
          .evaluate())
    (e.widget.key as ValueKey<String>).value.substring(
      'formula-suggestion-'.length,
    ),
];

void main() {
  group('opens', () {
    for (final (where, text) in [
      ('at the start', r'$'),
      ('after +', r'2 + $'),
      ('after * without spaces', r'2*$'),
      ('inside (', r'($'),
      ('after ( 2 * ', r'( 2 * $'),
      ('after whitespace', r'5 $'),
      ('after ×', r'5 × $'),
      ('after unicode minus', r'5 − $'),
    ]) {
      testWidgets(where, (tester) async {
        await pumpFormula(tester);
        await typeText(tester, text);
        expect(suggestions, findsOneWidget);
        expect(shown(tester).length, 6);
      });
    }

    testWidgets(r'not after $5 (currency) or inside numbers', (tester) async {
      await pumpFormula(tester);
      await typeText(tester, r'$5');
      expect(suggestions, findsNothing);
      await typeText(tester, r'$5 + 12');
      expect(suggestions, findsNothing);
    });

    testWidgets('not when formulas are off', (tester) async {
      await pumpFormula(tester, formulas: false);
      await typeText(tester, r'$');
      expect(suggestions, findsNothing);
    });
  });

  testWidgets('filters as typed: prefix matches first, then substring', (
    tester,
  ) async {
    await pumpFormula(tester);
    await typeText(tester, r'$r');
    expect(shown(tester), ['rate', 'rego', 'rent', 'fare', 'salary']);
    await typeText(tester, r'$re');
    expect(shown(tester), ['rego', 'rent', 'fare']);
    await typeText(tester, r'$ren');
    expect(shown(tester), ['rent']);
  });

  testWidgets('rows show value, unit badge and description', (tester) async {
    await pumpFormula(tester);
    await typeText(tester, r'$');
    final rent = suggestion('rent');
    expect(
      find.descendant(of: rent, matching: find.text(r'$1,200.00')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rent, matching: find.text('Weekly rent, Glebe flat')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rent, matching: find.text(r'$')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: suggestion('rate'), matching: find.text('5.5%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: suggestion('rate'), matching: find.text('%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: suggestion('weeks'), matching: find.text('52')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: suggestion('weeks'), matching: find.text('#')),
      findsOneWidget,
    );
  });

  testWidgets('↑/↓ move (wrapping), Enter inserts, no submit', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'2 * $re');
    expect(shown(tester), ['rego', 'rent', 'fare']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // wraps to rego
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // wraps to fare
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // rent
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'2 * $rent');
    expect(h.controller.selection, const TextSelection.collapsed(offset: 9));
    expect(suggestions, findsNothing);
    expect(h.submitted, isEmpty);
    expect(h.focus.hasFocus, isTrue);
    // The keyboard's Done right after the key (web sends both): swallowed.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.submitted, isEmpty);
    expect(h.focus.hasFocus, isTrue);
  });

  testWidgets('Done while the list is open inserts the highlighted row', (
    tester,
  ) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$sa');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$salary');
    expect(h.submitted, isEmpty);
    expect(h.focus.hasFocus, isTrue);
  });

  testWidgets('Tab inserts and keeps focus', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$we');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$weeks');
    expect(h.focus.hasFocus, isTrue);
    // List closed: Tab moves focus as today.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(h.focus.hasFocus, isFalse);
  });

  testWidgets('Esc closes the list only; the dialog stays open', (
    tester,
  ) async {
    final h = await pumpFormula(tester, inDialog: true);
    await typeText(tester, r'$r');
    expect(suggestions, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(suggestions, findsNothing);
    expect(find.byKey(const ValueKey('dialog')), findsOneWidget);
    expect(h.focus.hasFocus, isTrue);
    expect(h.controller.text, r'$r');
    // Typing re-opens it.
    await typeText(tester, r'$re');
    expect(suggestions, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // With no list open, Esc closes the dialog as today (after the guard).
    await tester.pump(const Duration(milliseconds: 450));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dialog')), findsNothing);
    expect(h.dialogsClosed, 1);
  });

  testWidgets('tap inserts (touch) and keeps focus', (tester) async {
    final h = await pumpFormula(tester, touch: true);
    await typeText(tester, r'5 + $');
    await tester.tap(suggestion('rego'), kind: PointerDeviceKind.touch);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'5 + $rego');
    expect(h.focus.hasFocus, isTrue);
    expect(suggestions, findsNothing);
  });

  testWidgets('mouse hover highlights, click inserts', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(suggestion('weeks')));
    await mouse.moveTo(tester.getCenter(suggestion('weeks')));
    await tester.pumpAndSettle();
    final sem = tester.getSemantics(suggestion('weeks'));
    expect(sem.flagsCollection.isSelected, Tristate.isTrue);
    await tester.tap(suggestion('weeks'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$weeks');
    expect(h.focus.hasFocus, isTrue);
  });

  testWidgets('insertion mid-text replaces the partial name', (tester) async {
    final h = await pumpFormula(tester);
    await setCaret(tester, r'2 * $re + 5', 7);
    expect(shown(tester).first, 'rego');
    await tester.tap(suggestion('rent'));
    await tester.pumpAndSettle();
    expect(h.controller.text, r'2 * $rent + 5');
    expect(h.controller.selection, const TextSelection.collapsed(offset: 9));
  });

  testWidgets('caret back in an existing name re-opens and replaces it all', (
    tester,
  ) async {
    final h = await pumpFormula(tester);
    await setCaret(tester, r'$rent / 4', 9);
    expect(suggestions, findsNothing);
    await setCaret(tester, r'$rent / 4', 3);
    expect(suggestions, findsOneWidget);
    expect(shown(tester), ['rego', 'rent', 'fare']); // prefix "re"
    await tester.tap(suggestion('rego'));
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$rego / 4');
    expect(h.controller.selection, const TextSelection.collapsed(offset: 5));
  });

  testWidgets('undo restores the typed text', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$re');
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$rego');
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(h.controller.text, r'$re');
  });

  testWidgets('Enter with the list closed submits', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$rent / 4');
    expect(suggestions, findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(h.submitted.single.value.toString(), '300');
    expect(h.submitted.single.expr, r'$rent / 4');
  });

  testWidgets('empty state: no variables', (tester) async {
    await pumpFormula(tester, scope: VariableScope.empty);
    await typeText(tester, r'$');
    expect(find.text('No variables yet'), findsOneWidget);
  });

  testWidgets('empty state: no match', (tester) async {
    await pumpFormula(tester);
    await typeText(tester, r'$xyz');
    expect(find.text('No variable named "\$xyz"'), findsOneWidget);
    // Manage / create actions arrive with the manager (012).
    expect(find.textContaining('Manage'), findsNothing);
    expect(find.textContaining('Create'), findsNothing);
  });

  testWidgets('320 px: the list fits, below; near the bottom it flips above', (
    tester,
  ) async {
    await pumpFormula(tester, width: 320, height: 640);
    await typeText(tester, r'$');
    expect(find.byKey(const ValueKey('formula-suggestions-below')), findsOne);
    final r = tester.getRect(suggestions);
    expect(r.left, greaterThanOrEqualTo(0));
    expect(r.right, lessThanOrEqualTo(320));
    expect(r.top, greaterThan(tester.getRect(amountField).bottom));
  });

  testWidgets('320 px near the bottom: flips above', (tester) async {
    await pumpFormula(tester, width: 320, height: 640, topPad: 460);
    await typeText(tester, r'$');
    expect(find.byKey(const ValueKey('formula-suggestions-above')), findsOne);
    final r = tester.getRect(suggestions);
    expect(r.right, lessThanOrEqualTo(320));
    expect(r.bottom, lessThan(tester.getRect(amountField).top));
    expect(r.top, greaterThanOrEqualTo(0));
  });

  testWidgets('keyboard (viewInsets) counts as no room below', (tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await pumpFormula(
      tester,
      width: 390,
      height: 844,
      topPad: 300,
      touch: true,
    );
    await typeText(tester, r'$');
    expect(find.byKey(const ValueKey('formula-suggestions-above')), findsOne);
  });

  testWidgets('semantics: container label, row labels, selected row', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpFormula(tester);
    await typeText(tester, r'$re');
    expect(
      find.bySemanticsLabel('Variable suggestions, 3 results'),
      findsOneWidget,
    );
    final rego = tester.getSemantics(suggestion('rego'));
    expect(rego.label, r'$rego, 850 dollars, money');
    expect(rego.flagsCollection.isSelected, Tristate.isTrue);
    expect(rego.flagsCollection.isButton, isTrue);
    expect(
      tester.getSemantics(suggestion('rent')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('focus loss closes the list', (tester) async {
    final h = await pumpFormula(tester);
    await typeText(tester, r'$');
    h.focus.unfocus();
    await tester.pumpAndSettle();
    expect(suggestions, findsNothing);
  });

  group('picker', () {
    testWidgets('desktop: opens the list at the caret and inserts', (
      tester,
    ) async {
      final h = await pumpFormula(tester, text: '2 * ');
      h.controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-amount-var-picker')));
      await tester.pumpAndSettle();
      expect(shown(tester).length, 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(h.controller.text, r'2 * $rate');
    });

    testWidgets('touch: a dialog with search, inserts at the caret', (
      tester,
    ) async {
      final h = await pumpFormula(tester, text: '2 * ', touch: true);
      h.controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.tap(find.byKey(const ValueKey('editor-amount-var-picker')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('formula-picker-dialog')), findsOne);
      await tester.enterText(
        find.byKey(const ValueKey('formula-picker-search')),
        'sal',
      );
      await tester.pumpAndSettle();
      await tester.tap(suggestion('salary'));
      await tester.pumpAndSettle();
      expect(h.controller.text, r'2 * $salary');
    });

    testWidgets('hidden with formulas off, or no variables', (tester) async {
      await pumpFormula(tester, formulas: false);
      expect(
        find.byKey(const ValueKey('editor-amount-var-picker')),
        findsNothing,
      );
    });

    testWidgets('hidden with no variables (nothing to manage before 012)', (
      tester,
    ) async {
      await pumpFormula(tester, scope: VariableScope.empty);
      expect(
        find.byKey(const ValueKey('editor-amount-var-picker')),
        findsNothing,
      );
    });
  });

  group('operator row', () {
    testWidgets('touch: shown while focused, keys insert, keep focus', (
      tester,
    ) async {
      final h = await pumpFormula(tester, touch: true);
      expect(find.byKey(const ValueKey('editor-amount-keys')), findsOne);
      await typeText(tester, '5');
      for (final k in ['*', '(', r'$']) {
        await tester.tap(
          find.byKey(ValueKey('editor-amount-key-$k')),
          kind: PointerDeviceKind.touch,
        );
        await tester.pumpAndSettle();
      }
      expect(h.controller.text, r'5*($');
      expect(h.focus.hasFocus, isTrue);
      expect(suggestions, findsOneWidget); // typing $ opens it
      await tester.tap(suggestion('rent'), kind: PointerDeviceKind.touch);
      await tester.pumpAndSettle();
      for (final k in ['-', '/', ')', '+', '.']) {
        await tester.tap(
          find.byKey(ValueKey('editor-amount-key-$k')),
          kind: PointerDeviceKind.touch,
        );
        await tester.pumpAndSettle();
      }
      expect(h.controller.text, r'5*($rent-/)+.');
      expect(h.focus.hasFocus, isTrue);
      h.focus.unfocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-amount-keys')), findsNothing);
    });

    testWidgets('never on desktop', (tester) async {
      await pumpFormula(tester);
      expect(find.byKey(const ValueKey('editor-amount-keys')), findsNothing);
    });

    testWidgets('keys are 40×40 at least', (tester) async {
      await pumpFormula(tester, touch: true, width: 320);
      for (final k in ['\$', '(', ')', '+', '-', '*', '/', '.']) {
        final s = tester.getSize(find.byKey(ValueKey('editor-amount-key-$k')));
        expect(s.width, greaterThanOrEqualTo(40));
        expect(s.height, greaterThanOrEqualTo(40));
      }
    });
  });

  testWidgets('help popover opens from the suffix', (tester) async {
    await pumpFormula(tester);
    await tester.tap(find.byKey(const ValueKey('editor-amount-help')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('formula-help')), findsOneWidget);
    expect(find.text('Use numbers, variables and + − × ÷ ( ).'), findsOne);
    expect(find.text(r'Type $ to pick a variable.'), findsOne);
  });

  testWidgets('RenderBox sanity: no overflow at 320 with list open', (
    tester,
  ) async {
    await pumpFormula(tester, width: 320, height: 568, touch: true);
    await typeText(tester, r'$');
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening help closes the list (it would paint over it)', (
    tester,
  ) async {
    await pumpFormula(tester);
    await typeText(tester, r'$r');
    expect(suggestions, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-amount-help')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('formula-help')), findsOneWidget);
    expect(suggestions, findsNothing);
  });

  testWidgets('the list goes with the field (no stray overlay entry)', (
    tester,
  ) async {
    await pumpFormula(tester);
    await typeText(tester, r'$r');
    expect(suggestions, findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(suggestions, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
