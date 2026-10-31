// Loan editing (spec 003 §5–§7): the Loan kind in the event editor, the
// simple / advanced / flat forms and their switching rules, the rate
// editor, the live preview from `/project`, save and server errors.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/timeline/occurrence_info.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/category_dropdown.dart';
import 'support/fake_categories.dart';
import 'support/fake_loans.dart';
import 'support/fake_streams.dart';

late FakeLoanStreamRepository streams;
late FakeLoanEventRepository events;

Future<void> pumpEditor(
  WidgetTester tester, {
  BudgetEvent? existing,
  List<BudgetEvent> inStream = const [],
  double width = 1200,
  bool hasLoan = false,
  bool readOnly = false,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final acc = BudgetStream.fromJson({
    ...testStream('acc', 'Mortgage').toJson(),
    'hasLoan': hasLoan,
  });
  streams = FakeLoanStreamRepository(
    streams: [acc, testStream('pay', 'Everyday')],
    summary: loanSummaryJson(),
  );
  events = FakeLoanEventRepository({
    'acc': [...inStream],
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
            readOnly: readOnly,
            initialDate: DateTime(2027, 1, 15),
            focusDate: existing == null ? null : DateTime(2027, 2, 15),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, String key, String text) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, text);
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  final f = find.text(text).last;
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// Past the preview's debounce.
Future<void> settlePreview(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [1200.0, 320.0]) {
    testWidgets('new simple loan: form, live preview, save (${width}px)', (
      tester,
    ) async {
      await pumpEditor(tester, width: width);
      expect(find.byKey(const ValueKey('editor-kind-loan')), findsOneWidget);
      await tapKey(tester, 'editor-kind-loan');
      expect(find.byKey(const ValueKey('loan-form')), findsOneWidget);
      // The loan's own fields replace the amount, transfer and schedule.
      expect(find.byKey(const ValueKey('editor-amount')), findsNothing);
      expect(find.text('Amount borrowed'), findsOneWidget);
      expect(find.byKey(const ValueKey('loan-charge-line')), findsOneWidget);
      expect(find.text('Interest charged monthly on the 15th'), findsOneWidget);

      await enter(tester, 'loan-principal', '500000');
      await enter(tester, 'loan-rate-0', '6');
      await settlePreview(tester);
      expect(streams.previews, isNotEmpty);
      final sent = streams.previews.last.draft;
      expect(sent.kind, 'loan');
      expect(sent.amount.toString(), '500000');
      expect(sent.recurrenceMode, RecurrenceMode.once);
      expect(sent.direction, EventDirection.debit);
      expect(sent.loan!['ratePeriods'][0]['ratePct'], '6');
      expect(sent.loan!['ratePeriods'][0]['from'], '2027-01-15');
      expect(streams.previews.last.replaces, isNull);
      expect(find.byKey(const ValueKey('loan-summary')), findsOneWidget);
      expect(find.byKey(const ValueKey('loan-summary-owed')), findsOneWidget);
      // No save options for a loan.
      expect(find.byKey(const ValueKey('editor-save-menu')), findsNothing);

      await pickCategory(tester, fakeCategoryId('Home loan'));
      await tapKey(tester, 'editor-save');
      expect(events.created, hasLength(1));
      final saved = events.created.single;
      expect(saved.isLoan, isTrue);
      expect(saved.name, 'Home loan');
      expect(saved.toCreateJson()['kind'], 'loan');
      expect(saved.toCreateJson()['loan']['termMonths'], 360);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Loan is not offered in a stream that has a loan', (
    tester,
  ) async {
    await pumpEditor(tester, inStream: [loanEvent()]);
    expect(find.byKey(const ValueKey('editor-kind-loan')), findsNothing);
    expect(find.text('Money out'), findsOneWidget);
  });

  testWidgets('a saved loan opens editable, kind locked, preview replaces it', (
    tester,
  ) async {
    final loan = loanEvent();
    await pumpEditor(tester, existing: loan, inStream: [loan], hasLoan: true);
    expect(find.byKey(const ValueKey('editor-loan-read-only')), findsNothing);
    expect(find.byKey(const ValueKey('loan-form')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-delete')), findsOneWidget);
    expect(find.text('Skip this one'), findsNothing);
    final principal = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('loan-principal')),
        matching: find.byType(TextField),
      ),
    );
    expect(principal.controller!.text, '600000');
    // Locked kind: tapping another kind does nothing.
    await tester.tap(find.text('Money out'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loan-form')), findsOneWidget);

    await enter(tester, 'loan-rate-0', '6.4');
    await settlePreview(tester);
    expect(streams.previews.last.replaces, 'loan1');
    await tapKey(tester, 'editor-save');
    expect(events.updated, hasLength(1));
    final u = events.updated.single;
    expect(u.id, 'loan1');
    expect(u.loan!['ratePeriods'][0]['ratePct'], '6.4');
    expect(u.recurrenceMode, RecurrenceMode.once);
    expect(u.interval, isNull);
    expect(u.transfer, isNull);
  });

  testWidgets('flat plan text (F1) at 320px', (tester) async {
    await pumpEditor(tester, width: 320);
    await tapKey(tester, 'editor-kind-loan');
    await tapText(tester, 'Flat rate');
    expect(find.byKey(const ValueKey('loan-advanced-disabled')), findsOne);
    await enter(tester, 'loan-principal', '10000');
    await enter(tester, 'loan-rate-0', '10');
    await enter(tester, 'loan-term-years', '2');
    await enter(tester, 'loan-term-months', '0');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Total interest \$2,000.00 · 24 instalments of \$83.33 (last \$83.41)'
        ' · Repayment \$500.00 (final \$500.00) · About 18.16% p.a. on a '
        'reducing balance',
      ),
      findsOneWidget,
    );
    expect(
      find.text("Paying off early doesn't reduce the interest."),
      findsOneWidget,
    );
    await settlePreview(tester);
    final sent = streams.previews.last.draft.loan!;
    expect(sent['interestType'], 'flat');
    expect(sent['chargeSchedule'], 'onRepaymentDates');
    expect(sent['chargeDay'], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching: advanced rates, flat confirm, back, simple blocked', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    await enter(tester, 'loan-principal', '500000');
    await enter(tester, 'loan-rate-0', '6');
    await tapKey(tester, 'loan-change-schedule');
    // Advanced: the rate editor and charge fields.
    expect(find.byKey(const ValueKey('loan-rate-from-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('loan-charge-schedule')), findsOneWidget);
    expect(find.byKey(const ValueKey('loan-day-count')), findsOneWidget);
    await tapKey(tester, 'loan-add-rate');
    expect(find.byKey(const ValueKey('loan-rate-1')), findsOneWidget);
    final r1 = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('loan-rate-1')),
        matching: find.byType(TextField),
      ),
    );
    expect(r1.controller!.text, '6');
    await enter(tester, 'loan-rate-1', '7.25');

    // Two rates: Simple is blocked with a reason.
    await tapText(tester, 'Simple');
    expect(find.byKey(const ValueKey('loan-simple-blocked')), findsOneWidget);
    expect(find.byKey(const ValueKey('loan-rate-1')), findsOneWidget);

    // Flat drops the later rate after a confirm.
    await tapText(tester, 'Flat rate');
    expect(find.text('Switch to a flat rate?'), findsOneWidget);
    await tapText(tester, 'Cancel');
    expect(find.byKey(const ValueKey('loan-rate-1')), findsOneWidget);
    await tapText(tester, 'Flat rate');
    await tapText(tester, 'Switch');
    expect(find.byKey(const ValueKey('loan-rate-1')), findsNothing);
    expect(find.byKey(const ValueKey('loan-flat-plan')), findsOneWidget);

    // Back to reducing: default schedule, simple.
    await tapText(tester, 'Reducing balance');
    expect(find.byKey(const ValueKey('loan-charge-line')), findsOneWidget);
    await settlePreview(tester);
    final sent = streams.previews.last.draft.loan!;
    expect(sent['interestType'], 'reducing');
    expect(sent['chargeSchedule'], 'monthly');
    expect(sent['chargeDay'], 'anniversary');
    expect(sent['ratePeriods'], hasLength(1));
  });

  testWidgets('rate rows: delete, and a server 400 lands on its field', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    await enter(tester, 'loan-principal', '500000');
    await enter(tester, 'loan-rate-0', '6');
    await tapKey(tester, 'loan-change-schedule');
    await tapKey(tester, 'loan-add-rate');
    await tapKey(tester, 'loan-rate-delete-1');
    expect(find.byKey(const ValueKey('loan-rate-1')), findsNothing);
    expect(find.byKey(const ValueKey('loan-rate-delete-0')), findsNothing);

    await pickCategory(tester, fakeCategoryId('Home loan'));
    events.saveError = 'loan.termMonths must be between 1 and 600';
    await tapKey(tester, 'editor-save');
    expect(events.created, isEmpty);
    expect(find.text('Must be between 1 and 600'), findsWidgets);
  });

  testWidgets('a missing amount blocks Save on the loan field', (tester) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    await pickCategory(tester, fakeCategoryId('Home loan'));
    await tapKey(tester, 'editor-save');
    expect(events.created, isEmpty);
    expect(find.text('Enter the amount borrowed'), findsWidgets);
    // Preview waits for a valid loan.
    await settlePreview(tester);
    expect(streams.previews, isEmpty);
  });

  testWidgets('charge schedule: day 31, then on each repayment date', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    await enter(tester, 'loan-principal', '500000');
    await enter(tester, 'loan-rate-0', '6');
    await tapKey(tester, 'loan-change-schedule');
    await tapKey(tester, 'loan-charge-day');
    await tapText(tester, 'Day of month…');
    expect(find.text('Short months use their last day'), findsOneWidget);
    await enter(tester, 'loan-charge-day-number', '31');
    await settlePreview(tester);
    var sent = streams.previews.last.draft.loan!;
    expect(sent['chargeSchedule'], 'monthly');
    expect(sent['chargeDay'], 31);

    await tapKey(tester, 'loan-charge-schedule');
    await tapText(tester, 'On each repayment date');
    expect(find.byKey(const ValueKey('loan-charge-day')), findsNothing);
    await settlePreview(tester);
    sent = streams.previews.last.draft.loan!;
    expect(sent['chargeSchedule'], 'onRepaymentDates');
    await pickCategory(tester, fakeCategoryId('Home loan'));
    await tapKey(tester, 'editor-save');
    expect(events.created.single.loan!['chargeSchedule'], 'onRepaymentDates');
    expect(events.created.single.loan!['mode'], 'advanced');
  });

  testWidgets('first repayment defaults one period after the start', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    String first() => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('loan-first-repayment')),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data)
        .join('|');
    expect(first(), contains(formatOccurrenceDate(DateTime(2027, 2, 15))));
    for (final (label, date) in [
      ('Weekly', DateTime(2027, 1, 22)),
      ('Fortnightly', DateTime(2027, 1, 29)),
      ('Monthly', DateTime(2027, 2, 15)),
    ]) {
      await tapKey(tester, 'loan-frequency');
      await tapText(tester, label);
      expect(first(), contains(formatOccurrenceDate(date)), reason: label);
    }
  });

  testWidgets('three rate periods: add, reorder by date, first row locked', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tapKey(tester, 'editor-kind-loan');
    await enter(tester, 'loan-principal', '500000');
    await enter(tester, 'loan-rate-0', '6');
    await tapKey(tester, 'loan-change-schedule');
    await tapKey(tester, 'loan-add-rate');
    await enter(tester, 'loan-rate-1', '7');
    await tapKey(tester, 'loan-add-rate');
    await enter(tester, 'loan-rate-2', '8');
    // The first row has no delete and no date picker.
    expect(find.byKey(const ValueKey('loan-rate-delete-0')), findsNothing);
    await tapKey(tester, 'loan-rate-from-0');
    expect(find.byType(DatePickerDialog), findsNothing);
    // Move the third row before the second: they re-sort by date.
    await tapKey(tester, 'loan-rate-from-2');
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.byType(TextField),
      ),
      '07/15/2027',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await settlePreview(tester);
    final periods = (streams.previews.last.draft.loan!['ratePeriods'] as List)
        .cast<Map>();
    expect(
      [for (final p in periods) p['from']],
      ['2027-01-15', '2027-07-15', '2028-01-15'],
    );
    expect([for (final p in periods) p['ratePct']], ['6', '8', '7']);
    await tapKey(tester, 'loan-rate-delete-1');
    await settlePreview(tester);
    expect(streams.previews.last.draft.loan!['ratePeriods'], hasLength(2));
  });

  testWidgets('a viewer sees a loan read-only', (tester) async {
    final loan = loanEvent();
    await pumpEditor(
      tester,
      existing: loan,
      inStream: [loan],
      hasLoan: true,
      readOnly: true,
    );
    expect(find.byKey(const ValueKey('editor-view-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('loan-form')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-save')), findsNothing);
    final principal = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('loan-principal')),
        matching: find.byType(TextField),
      ),
    );
    expect(principal.enabled, isFalse);
    expect(find.byKey(const ValueKey('loan-change-schedule')), findsNothing);
  });
}
