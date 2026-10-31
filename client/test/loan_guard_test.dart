// Loan events (spec 002, phase 1): this client reads loans but cannot edit
// them yet. Parsing keeps the raw terms; the editor shows a loan read-only
// with no Save; derived interest occurrences parse their flags; a loan
// stream's below-zero balance is not shown as an alert.
import 'package:budget_client/app.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/theme/app_theme.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';
import 'support/fake_categories.dart';
import 'support/fake_streams.dart';

const _terms = {
  'v': 1,
  'mode': 'simple',
  'interestType': 'reducing',
  'termMonths': 360,
  'repaymentFrequency': 'monthly',
  'firstRepaymentDate': '2027-02-15',
  'chargeSchedule': 'monthly',
  'chargeDay': 'anniversary',
  'dayCount': '365',
  'ratePeriods': [
    {
      'from': '2027-01-15',
      'ratePct': '5.89',
      'type': 'fixed',
      'interestOnly': false,
      'offsetApplies': false,
    },
  ],
};

Map<String, dynamic> _loanJson() => {
  'id': 'loan1',
  'streamId': 'acc',
  'name': 'Home loan',
  'direction': 'debit',
  'amount': '600000',
  'startDate': '2027-01-15',
  'recurrenceMode': 'once',
  'endMode': 'never',
  'enabled': true,
  'version': 1,
  'kind': 'loan',
  'loan': _terms,
  'overrides': <Object>[],
};

void main() {
  test('parses kind, raw loan terms, derived occurrences and hasLoan', () {
    final loan = BudgetEvent.fromJson(_loanJson());
    expect(loan.isLoan, isTrue);
    expect(loan.loan!['ratePeriods'][0]['ratePct'], '5.89');
    expect(loan.copyWith(name: 'Mortgage').isLoan, isTrue);
    expect(loan.toJson()['kind'], 'loan');
    expect(loan.toJson()['loan'], _terms);

    final std = BudgetEvent.fromJson({
      ..._loanJson(),
      'kind': 'standard',
      'loan': null,
    });
    expect(std.isLoan, isFalse);
    expect(std.toJson().containsKey('kind'), isFalse);
    // Older servers send neither field.
    final old = BudgetEvent.fromJson(
      {..._loanJson()}
        ..remove('kind')
        ..remove('loan'),
    );
    expect(old.isLoan, isFalse);
    expect(old.loan, isNull);

    final o = Occurrence.fromJson({
      'eventId': 'loan1',
      'date': '2027-02-15',
      'signedDelta': '-2902.68',
      'skipped': false,
      'component': 'interest',
      'derived': true,
    });
    expect(o.derived, isTrue);
    expect(o.component, 'interest');
    expect(o.payout, isFalse);
    expect(o.tagged(streamId: 's').derived, isTrue);
    final plain = Occurrence.fromJson({
      'eventId': 'e',
      'date': '2027-02-15',
      'signedDelta': '1',
      'skipped': false,
    });
    expect(plain.derived, isFalse);
    expect(plain.component, isNull);

    final s = BudgetStream.fromJson({
      ...testStream('a', 'A').toJson(),
      'hasLoan': true,
    });
    expect(s.hasLoan, isTrue);
    expect(s.copyWith(name: 'B').hasLoan, isTrue);
    expect(s.withSharing(testStream('a', 'A')).hasLoan, isTrue);
  });

  testWidgets('a loan opens read-only: note, disabled fields, no Save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final loan = BudgetEvent.fromJson(_loanJson());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryRepositoryProvider.overrideWith(
            (ref) => FakeCategoryRepository(
              ref.watch(eventRepositoryProvider),
              ['Groceries'],
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EventEditor(
              streamId: 'acc',
              existing: loan,
              focusDate: DateTime(2027, 2, 15),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-loan-read-only')), findsOneWidget);
    expect(
      find.text('Loan editing is coming in the next update'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-view-only')), findsNothing);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    expect(find.byKey(const ValueKey('editor-save-menu')), findsNothing);
    expect(find.text('Skip this one'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
    // Deleting a loan stays possible.
    expect(find.byKey(const ValueKey('editor-delete')), findsOneWidget);
  });

  testWidgets('a loan stream below zero is not coloured as an alert', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final loanStream = BudgetStream.fromJson({
      ...testStream('l1', 'Mortgage').toJson(),
      'hasLoan': true,
    });
    final repo = FakeStreamRepository(
      streams: [testStream('a1', 'Everyday'), loanStream],
    );
    final c = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(
          FakeAuthRepository(user: adminUser),
        ),
        streamRepositoryProvider.overrideWithValue(repo),
        todayBalanceProvider.overrideWith(
          (ref, id) async => Decimal.parse('-500000'),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const BudgetApp()),
    );
    await tester.pumpAndSettle();
    Color? colourIn(String id) {
      final t = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(ValueKey('stream-card-$id')),
              matching: find.textContaining('500,000'),
            )
            .first,
      );
      return t.style?.color;
    }

    expect(colourIn('a1'), AppTheme.debitColor);
    expect(colourIn('l1'), AppTheme.text);
  });
}
