// Loan offset account (spec 004 §15–§16): the owner-only "Offset account"
// picker (own, loan-free streams other than this one, plus None), its
// threshold helper, read-only for editors and hidden when not shared,
// unlink on Flat, the active "Offset applies" boxes, the summary benefit
// line, the stream dialog helper and the streams-list indicator.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_client/features/loans/loan_offset_field.dart';
import 'package:budget_client/features/streams/streams_page.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/stream_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_categories.dart';
import 'support/fake_loans.dart';
import 'support/fake_streams.dart';

late FakeLoanStreamRepository streams;
late FakeLoanEventRepository events;

BudgetStream _s(String id, String name, Map<String, dynamic> extra) =>
    BudgetStream.fromJson({...testStream(id, name).toJson(), ...extra});

Map<String, dynamic> offsetSummary({bool visible = true}) => {
  'streamId': visible ? 'pay' : null,
  'streamName': visible ? 'Everyday' : null,
  'visible': visible,
  'usableToday': '12000.00',
  'thresholdUsed': '5000.00',
  'interestSaved': '84210.55',
  'totalInterestWithoutOffset': '700000.00',
  'payoffDateWithoutOffset': '2057-01-15',
  'monthsSaved': 41,
};

Future<void> pumpEditor(
  WidgetTester tester, {
  required BudgetEvent existing,
  Role role = Role.owner,
  double width = 1200,
  Map<String, dynamic>? offset,
}) async {
  tester.view.physicalSize = Size(width, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shared = role != Role.owner;
  streams = FakeLoanStreamRepository(
    streams: [
      _s('acc', 'Mortgage', {
        'hasLoan': true,
        'role': role.name,
        'shared': shared,
        if (shared) 'ownerId': 'other',
      }),
      _s('pay', 'Everyday', {'lossThreshold': '5000.00'}),
      _s('car', 'Car loan', {'hasLoan': true}),
      _s('sav', 'Savings', {'lossThreshold': '-200.00'}),
      _s('theirs', 'Their account', {'shared': true, 'role': 'editor'}),
    ],
    summary: {...loanSummaryJson(), 'offset': ?offset},
  );
  events = FakeLoanEventRepository({
    'acc': [existing],
    'pay': [],
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(streams),
        eventRepositoryProvider.overrideWithValue(events),
        categoryRepositoryProvider.overrideWith(
          (ref) => FakeCategoryRepository(events, ['Home loan']),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EventEditor(
            streamId: 'acc',
            existing: existing,
            initialDate: DateTime(2027, 1, 15),
            focusDate: DateTime(2027, 2, 15),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

BudgetEvent linkedLoan({List<String> ids = const [], bool hidden = false}) =>
    BudgetEvent.fromJson({
      ...loanEvent().toJson(),
      'offsetStreamIds': ids,
      'offsetHidden': ?(hidden ? true : null),
    });

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f.last);
  await tester.pumpAndSettle();
  await tester.tap(f.last);
  await tester.pumpAndSettle();
}

Future<void> settlePreview(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}

String helperOf(WidgetTester tester) => tester
    .widget<InputDecorator>(
      find.descendant(
        of: find.byKey(const ValueKey('loan-offset')),
        matching: find.byType(InputDecorator),
      ),
    )
    .decoration
    .helperText!;

void main() {
  for (final width in [1200.0, 320.0]) {
    testWidgets('owner links an offset: filtered picker, helper, preview, '
        'save sends the link (${width}px)', (tester) async {
      await pumpEditor(
        tester,
        existing: linkedLoan(),
        width: width,
        offset: offsetSummary(),
      );
      expect(find.text('None'), findsOneWidget);
      expect(helperOf(tester), startsWith('Optional.'));
      // Offset applies is inactive until a stream is linked.
      final box = find.descendant(
        of: find.byKey(const ValueKey('loan-rate-offset-0')),
        matching: find.byType(Checkbox),
      );
      expect(find.byKey(const ValueKey('loan-rate-offset-0')), findsNothing);
      expect(box, findsNothing); // Simple mode: no rate rows.

      await tapKey(tester, 'loan-offset');
      // My own loan-free streams other than this one; None first.
      expect(find.byKey(const ValueKey('loan-offset-none-option')), findsOne);
      expect(find.byKey(const ValueKey('loan-offset-stream-pay')), findsOne);
      expect(find.byKey(const ValueKey('loan-offset-stream-sav')), findsOne);
      expect(
        find.byKey(const ValueKey('loan-offset-stream-acc')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('loan-offset-stream-car')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('loan-offset-stream-theirs')),
        findsNothing,
      );
      await tapKey(tester, 'loan-offset-stream-pay');
      expect(find.text('Everyday'), findsWidgets);
      expect(
        helperOf(tester),
        'Only the balance above its alert threshold (\$5,000.00) reduces '
        'interest.',
      );

      await settlePreview(tester);
      final sent = streams.previews.last.draft.toCreateJson();
      expect(sent['offsetStreamIds'], ['pay']);
      // Simple mode: the offset applies to the whole loan.
      expect(sent['loan']['ratePeriods'][0]['offsetApplies'], isTrue);
      // The summary's benefit line and usable offset.
      expect(
        find.text(
          'Offset saves \$84,210.55 interest and pays the loan off 41 '
          'months sooner (by 15 Jan 2057)',
        ),
        findsOneWidget,
      );
      expect(find.text('\$12,000.00'), findsOneWidget);

      await tapKey(tester, 'editor-save');
      expect(events.updated, hasLength(1));
      expect(events.updated.single.toCreateJson()['offsetStreamIds'], ['pay']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a negative threshold shows as \$0.00 in the helper', (
    tester,
  ) async {
    await pumpEditor(tester, existing: linkedLoan(ids: ['sav']));
    expect(find.text('Savings'), findsWidgets);
    expect(
      helperOf(tester),
      'Only the balance above its alert threshold (\$0.00) reduces interest.',
    );
  });

  testWidgets('owner saving other edits does not send the link', (
    tester,
  ) async {
    await pumpEditor(tester, existing: linkedLoan(ids: ['pay']));
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('loan-rate-0')),
        matching: find.byType(TextField),
      ),
      '6.1',
    );
    await tester.pump();
    await tapKey(tester, 'editor-save');
    final body = events.updated.single.toCreateJson();
    expect(body.containsKey('offsetStreamIds'), isFalse);
  });

  testWidgets('owner unlinks with None: sends []', (tester) async {
    await pumpEditor(tester, existing: linkedLoan(ids: ['pay']));
    await tapKey(tester, 'loan-offset');
    await tapKey(tester, 'loan-offset-none-option');
    expect(helperOf(tester), startsWith('Optional.'));
    await tapKey(tester, 'editor-save');
    expect(events.updated.single.toCreateJson()['offsetStreamIds'], isEmpty);
  });

  testWidgets('advanced: Offset applies active once linked; added fixed '
      'periods default off, variable on', (tester) async {
    await pumpEditor(tester, existing: linkedLoan(ids: ['pay']));
    await tapKey(tester, 'loan-change-schedule');
    Checkbox box(int i) => tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(ValueKey('loan-rate-offset-$i')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(box(0).onChanged, isNotNull);
    // From Simple: the offset kept applying to the first period.
    expect(box(0).value, isTrue);
    await tapKey(tester, 'loan-add-rate');
    // The added period copies the (fixed) type: unchecked.
    expect(box(1).value, isFalse);
    await tapKey(tester, 'loan-rate-offset-1');
    expect(box(1).value, isTrue);
    await tapKey(tester, 'loan-rate-offset-0');
    await tapKey(tester, 'loan-rate-offset-1');
    expect(find.byKey(const ValueKey('loan-offset-none-applies')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching a linked loan to Flat asks to unlink first', (
    tester,
  ) async {
    await pumpEditor(tester, existing: linkedLoan(ids: ['pay']));
    await tester.tap(find.text('Flat rate'));
    await tester.pumpAndSettle();
    expect(find.text('Unlink the offset account?'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loan-offset')), findsOneWidget);
    await tester.tap(find.text('Flat rate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlink and switch'));
    await tester.pumpAndSettle();
    // Hidden for flat-rate loans.
    expect(find.byKey(const ValueKey('loan-offset')), findsNothing);
    await tapKey(tester, 'editor-save');
    final body = events.updated.single.toCreateJson();
    expect(body['offsetStreamIds'], isEmpty);
    expect(body['loan']['interestType'], 'flat');
  });

  testWidgets('an editor sees the offset read-only and never sends it', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      existing: linkedLoan(ids: ['pay']),
      role: Role.editor,
    );
    expect(find.text('Everyday'), findsWidgets);
    final tap = tester.widget<InkWell>(
      find.byKey(const ValueKey('loan-offset')),
    );
    expect(tap.onTap, isNull);
    await tester.tap(find.byKey(const ValueKey('loan-offset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loan-offset-none-option')), findsNothing);
    // Flat is blocked: only the owner can unlink.
    await tester.tap(find.text('Flat rate'));
    await tester.pumpAndSettle();
    expect(find.text("Can't switch to a flat rate"), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tapKey(tester, 'editor-save');
    final body = events.updated.single.toCreateJson();
    expect(body.containsKey('offsetStreamIds'), isFalse);
    expect(body['loan']['interestType'], 'reducing');
  });

  testWidgets('an editor without access sees "not shared with you"', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      existing: linkedLoan(hidden: true),
      role: Role.editor,
      offset: offsetSummary(visible: false),
    );
    await settlePreview(tester);
    expect(
      find.text('Linked offset account (not shared with you)'),
      findsNWidgets(2), // the field and the summary row
    );
    expect(find.textContaining('Offset saves'), findsOneWidget);
  });

  test('offset JSON: events, summary, stream refs', () {
    final e = linkedLoan(ids: ['pay']);
    expect(e.offsetStreamIds, ['pay']);
    expect(e.toJson()['offsetStreamIds'], ['pay']);
    expect(e.toCreateJson().containsKey('offsetStreamIds'), isFalse);
    expect(
      e.copyWith(offsetChange: const []).toCreateJson()['offsetStreamIds'],
      isEmpty,
    );
    final s = LoanSummary.fromJson({
      ...loanSummaryJson(),
      'offset': offsetSummary(),
    });
    expect(s.offset!.monthsSaved, 41);
    expect(s.offset!.interestSaved.toString(), '84210.55');
    expect(LoanSummary.fromJson(loanSummaryJson()).offset, isNull);
    final noMove = LoanOffsetSummary.fromJson({
      ...offsetSummary(),
      'monthsSaved': null,
    });
    expect(
      offsetBenefitText(noMove, DateTime(2053, 9, 15)),
      'Offset saves \$84,210.55 interest',
    );
    expect(
      offsetBenefitText(s.offset!, DateTime(2053, 9, 15)),
      'Offset saves \$84,210.55 interest and pays the loan off 41 months '
      'sooner (by 15 Sep 2053)',
    );
  });

  test('candidates, threshold helper and streams-list indicator', () {
    final pay = _s('pay', 'Everyday', {
      'offsetFor': [
        {'streamId': 'acc', 'name': 'Mortgage', 'visible': true},
      ],
    });
    final loan = _s('acc', 'Mortgage', {
      'hasLoan': true,
      'offset': {'streamId': 'pay', 'name': 'Everyday', 'visible': true},
    });
    final hiddenLoan = _s('acc', 'Mortgage', {
      'hasLoan': true,
      'offset': {'streamId': null, 'name': null, 'visible': false},
    });
    expect(offsetCandidate(pay, 'acc'), isTrue);
    expect(offsetCandidate(loan, 'x'), isFalse);
    expect(offsetCandidate(pay, 'pay'), isFalse);
    expect(
      offsetCandidate(_s('t', 'T', {'shared': true, 'role': 'editor'}), 'acc'),
      isFalse,
    );
    expect(
      thresholdHelper(pay),
      'Balances below this show in red. Also the zero for the offset on '
      'Mortgage',
    );
    expect(thresholdHelper(loan), 'Balances below this show in red');
    expect(offsetIndicator(pay), 'Offset for Mortgage');
    expect(offsetIndicator(loan), 'Offset: Everyday');
    expect(offsetIndicator(hiddenLoan), 'Offset: a stream not shared with you');
    expect(offsetIndicator(_s('z', 'Z', {})), isNull);
    // A single-stream fetch picks up the list's links.
    final single = _s('pay', 'Everyday', {});
    expect(single.withOffsetLinks(pay).offsetFor.single.name, 'Mortgage');
    expect(single.withOffsetLinks(null).offsetFor, isEmpty);
  });
}
