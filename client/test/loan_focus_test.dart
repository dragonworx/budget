// Typing in a loan field keeps focus while the live preview reloads.
//
// On the web, a focused field's input lives inside the semantics tree; when
// its semantics parent changed, the browser blurred the input and the field
// lost focus about 400 ms after its value first became valid (the preview's
// progress bar appearing regrouped the loan card's semantics). The event
// editor's cards are now fixed semantics containers, so the field's
// semantics ancestry, focus, text and caret survive the reload.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';
import 'support/fake_loans.dart';
import 'support/fake_streams.dart';
import 'variables/manager_support.dart';

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

/// The semantics node ids from [key]'s field up to the root.
List<int> _ancestry(WidgetTester tester, String key) => [
  for (
    SemanticsNode? n = tester.getSemantics(_input(key));
    n != null;
    n = n.parent
  )
    n.id,
];

Future<void> _pump(WidgetTester tester, {required bool advanced}) async {
  tester.view.physicalSize = const Size(420, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ServerFeatures.variables = true;
  addTearDown(() => ServerFeatures.variables = false);
  final terms = loanTermsJson(mode: advanced ? 'advanced' : 'simple')
    ..['chargeDay'] = advanced ? 20 : 'anniversary';
  final loan = loanEvent(terms: terms);
  final acc = BudgetStream.fromJson({
    ...testStream('acc', 'Mortgage').toJson(),
    'hasLoan': true,
  });
  final streams = FakeLoanStreamRepository(
    streams: [acc, testStream('pay', 'Everyday')],
    summary: loanSummaryJson(),
  );
  final events = FakeLoanEventRepository({
    'acc': [loan],
    'pay': [],
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(streams),
        eventRepositoryProvider.overrideWithValue(events),
        variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(events, ['Home loan']),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'acc',
            existing: loan,
            initialDate: DateTime(2027, 1, 15),
            focusDate: DateTime(2027, 2, 15),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const cases = [
    (key: 'loan-principal', first: '500000', more: ' + 1', advanced: false),
    (key: 'loan-rate-0', first: '6', more: ' / 2', advanced: false),
    (key: 'loan-term-years', first: '25', more: ' + 1', advanced: false),
    (key: 'loan-term-months', first: '6', more: ' + 1', advanced: false),
    (key: 'loan-rate-0', first: '6', more: ' / 2', advanced: true),
    (key: 'loan-charge-day-number', first: '12', more: ' + 1', advanced: true),
  ];
  for (final c in cases) {
    final mode = c.advanced ? 'advanced' : 'simple';
    testWidgets('${c.key} ($mode) keeps focus, text and caret across the '
        'preview reload', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, advanced: c.advanced);
      final input = _input(c.key);
      await tester.ensureVisible(input);
      await tester.pumpAndSettle();
      await tester.showKeyboard(input);
      await tester.enterText(input, c.first);
      await tester.pump();
      final before = _ancestry(tester, c.key);
      // The preview's debounce fires: its progress bar shows...
      await tester.pump(const Duration(milliseconds: 401));
      expect(_ancestry(tester, c.key), before, reason: 'while loading');
      // ...the user keeps typing...
      final full = '${c.first}${c.more}';
      await tester.enterText(input, full);
      await tester.pump();
      // ...and the preview lands.
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(_ancestry(tester, c.key), before, reason: 'after the reload');
      final field = tester.widget<EditableText>(input);
      expect(field.focusNode.hasFocus, isTrue);
      expect(field.controller.text, full);
      expect(
        field.controller.selection,
        TextSelection.collapsed(offset: full.length),
      );
      semantics.dispose();
    });
  }
}
