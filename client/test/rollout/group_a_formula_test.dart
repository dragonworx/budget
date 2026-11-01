// Spec 013 group A: the stream dialog's seed balance and alert threshold
// and the loan "Set up repayments" amount take formulas. A formula is
// saved as its text (the number is the resolved value), saved errors show
// on open, and with formulas off the fields behave exactly as before.
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/loans/loan_models.dart';
import 'package:budget_client/features/loans/loan_summary_panel.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/formula/formula_controller.dart';
import 'package:budget_client/widgets/stream_dialog.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_categories.dart';
import '../support/fake_loans.dart';
import '../support/fake_streams.dart';
import '../variables/manager_support.dart';

Finder _k(String key) => find.byKey(ValueKey(key));

EditableText _input(WidgetTester tester, String key) =>
    tester.widget<EditableText>(
      find.descendant(of: _k(key), matching: find.byType(EditableText)),
    );

/// The error line under [key]'s field (null when none).
/// (In touch mode a focused field shows it under the keys row instead.)
String? _error(WidgetTester tester, String key) {
  final under = find.byKey(ValueKey('$key-error'));
  if (under.evaluate().isNotEmpty) return tester.widget<Text>(under).data;
  return tester
      .widget<InputDecorator>(
        find.descendant(of: _k(key), matching: find.byType(InputDecorator)),
      )
      .decoration
      .errorText;
}

Future<void> _typeIn(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find.descendant(of: _k(key), matching: find.byType(EditableText)),
    text,
  );
  await tester.pumpAndSettle();
}

Future<List<BudgetStream>> _stream(
  WidgetTester tester, {
  BudgetStream? existing,
  bool on = true,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ServerFeatures.variables = on;
  final saved = <BudgetStream>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
        streamRepositoryProvider.overrideWithValue(FakeStreams(Role.owner)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showStreamDialog(
              context,
              existing: existing,
              onSave: (s) async {
                saved.add(s);
                return s;
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return saved;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(_k('stream-save'));
  await tester.pumpAndSettle();
}

BudgetStream _existing({
  String? seedExpr,
  String? lossExpr,
  Map<String, dynamic>? errors,
}) {
  final on = ServerFeatures.variables;
  ServerFeatures.variables = true;
  final s = BudgetStream.fromJson({
    ...testStream('acc', 'Everyday').toJson(),
    'seedBalance': '2400',
    'lossThreshold': '1200',
    'seedBalanceExpr': ?seedExpr,
    'lossThresholdExpr': ?lossExpr,
    'exprErrors': ?errors,
  });
  ServerFeatures.variables = on;
  return s;
}

void main() {
  tearDown(() => ServerFeatures.variables = false);

  group('stream dialog', () {
    testWidgets('new stream: seed and threshold take formulas', (tester) async {
      final saved = await _stream(tester);
      expect(
        _input(tester, 'stream-seed').controller,
        isA<FormulaEditingController>(),
      );
      await _typeIn(tester, 'stream-name', 'Holiday');
      await _typeIn(tester, 'stream-seed', r'$rent * 2');
      await _typeIn(tester, 'stream-threshold', r'$rent / 4');
      await _save(tester);
      final s = saved.single;
      expect(s.seedBalance, Decimal.fromInt(2400));
      expect(s.seedBalanceExpr, r'$rent * 2');
      expect(s.lossThreshold, Decimal.fromInt(300));
      expect(s.lossThresholdExpr, r'$rent / 4');
      final json = s.toJson();
      expect(json['seedBalanceExpr'], r'$rent * 2');
      expect(json['lossThresholdExpr'], r'$rent / 4');
    });

    testWidgets('plain numbers send no formula; empty threshold is 0', (
      tester,
    ) async {
      final saved = await _stream(tester);
      await _typeIn(tester, 'stream-name', 'Holiday');
      await _typeIn(tester, 'stream-seed', '-1,250.50');
      await _typeIn(tester, 'stream-threshold', '');
      await _save(tester);
      final s = saved.single;
      expect(s.seedBalance, Decimal.parse('-1250.5'));
      expect(s.seedBalanceExpr, isNull);
      expect(s.lossThreshold, Decimal.zero);
      expect(s.lossThresholdExpr, isNull);
      expect(s.toJson().containsKey('seedBalanceExpr'), isFalse);
    });

    testWidgets('errors wait for the first Save, then update live', (
      tester,
    ) async {
      final saved = await _stream(tester);
      await _typeIn(tester, 'stream-name', 'Holiday');
      await _typeIn(tester, 'stream-seed', r'$nope + 1');
      // No error before Save (as today).
      expect(_error(tester, 'stream-seed'), isNull);
      await _save(tester);
      expect(saved, isEmpty);
      expect(_error(tester, 'stream-seed'), contains('nope'));
      await _typeIn(tester, 'stream-seed', r'$rent');
      expect(_error(tester, 'stream-seed'), isNull);
      await _save(tester);
      expect(saved.single.seedBalanceExpr, r'$rent');
    });

    testWidgets('editing shows the saved formula and its saved error', (
      tester,
    ) async {
      ServerFeatures.variables = true;
      final e = _existing(
        seedExpr: r'$rent * 2',
        lossExpr: r'$gone',
        errors: {
          'lossThreshold': {
            'code': 'unknownVariable',
            'message': r'No variable called $gone',
          },
        },
      );
      final saved = await _stream(tester, existing: e);
      expect(_input(tester, 'stream-seed').controller.text, r'$rent * 2');
      expect(_input(tester, 'stream-threshold').controller.text, r'$gone');
      final c =
          _input(tester, 'stream-threshold').controller
              as FormulaEditingController;
      expect(c.formula.flagged, isTrue);
      await _typeIn(tester, 'stream-threshold', '100');
      await _save(tester);
      expect(saved.single.lossThreshold, Decimal.fromInt(100));
      expect(saved.single.lossThresholdExpr, isNull);
      expect(saved.single.seedBalanceExpr, r'$rent * 2');
    });

    testWidgets('formulas off: the stored number, today\'s messages', (
      tester,
    ) async {
      final e = _existing(seedExpr: r'$rent * 2');
      final saved = await _stream(tester, existing: e, on: false);
      expect(_input(tester, 'stream-seed').controller.text, '2400');
      await _typeIn(tester, 'stream-seed', r'$rent');
      await _save(tester);
      expect(saved, isEmpty);
      expect(
        find.text('Enter an amount, e.g. 2500 or -120.50'),
        findsOneWidget,
      );
      await _typeIn(tester, 'stream-seed', '10');
      await _save(tester);
      expect(saved.single.seedBalance, Decimal.fromInt(10));
      expect(saved.single.toJson().containsKey('seedBalanceExpr'), isFalse);
    });
  });

  group('loan setup amount', () {
    Future<FakeLoanEventRepository> pump(WidgetTester tester, bool on) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ServerFeatures.variables = on;
      final acc = BudgetStream.fromJson({
        ...testStream('acc', 'Mortgage').toJson(),
        'hasLoan': true,
      });
      final events = FakeLoanEventRepository({
        'acc': [loanEvent()],
        'pay': [],
      });
      final c = ProviderContainer(
        overrides: [
          streamRepositoryProvider.overrideWithValue(
            FakeLoanStreamRepository(
              streams: [acc, testStream('pay', 'Everyday')],
              summary: loanSummaryJson(),
            ),
          ),
          eventRepositoryProvider.overrideWithValue(events),
          categoryRepositoryProvider.overrideWith(
            (ref) => FakeCategoryRepository(events, ['Loan repayment']),
          ),
          variableRepositoryProvider.overrideWithValue(FakeVars(baseVars())),
        ],
      );
      addTearDown(c.dispose);
      await c.read(streamsProvider.future);
      await c.read(eventsProvider('acc').future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LoanSummaryPanel(
                  streamId: 'acc',
                  summary: LoanSummary.fromJson(
                    loanSummaryJson(warnings: ['repaymentScheduleMismatch']),
                  ),
                  actions: true,
                  today: DateTime(2027, 2, 20),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(_k('loan-setup-repayments'));
      await tester.pumpAndSettle();
      await tester.tap(_k('loan-setup-repayments'));
      await tester.pumpAndSettle();
      return events;
    }

    Future<void> create(WidgetTester tester) async {
      await tester.tap(_k('loan-setup-create'));
      await tester.pumpAndSettle();
    }

    bool createEnabled(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(_k('loan-setup-create')).enabled;

    testWidgets('a formula repayment is created with its text', (tester) async {
      final events = await pump(tester, true);
      await _typeIn(tester, 'loan-setup-amount', r'$rent * 3');
      expect(createEnabled(tester), isTrue);
      await create(tester);
      expect(events.created.single.amount, Decimal.fromInt(3600));
      expect(events.createdJson.single['amountExpr'], r'$rent * 3');
    });

    testWidgets('a plain number creates no formula', (tester) async {
      final events = await pump(tester, true);
      await _typeIn(tester, 'loan-setup-amount', '3,100');
      await create(tester);
      expect(events.created.single.amount, Decimal.fromInt(3100));
      expect(events.createdJson.single.containsKey('amountExpr'), isFalse);
    });

    testWidgets('a bad plain number only disables Create (no error line)', (
      tester,
    ) async {
      await pump(tester, true);
      await _typeIn(tester, 'loan-setup-amount', 'abc');
      expect(createEnabled(tester), isFalse);
      expect(_error(tester, 'loan-setup-amount'), isNull);
      // A broken formula explains itself.
      await _typeIn(tester, 'loan-setup-amount', r'$nope + 1');
      expect(createEnabled(tester), isFalse);
      expect(_error(tester, 'loan-setup-amount'), contains('nope'));
    });

    testWidgets('formulas off: a formula is just not a number', (tester) async {
      final events = await pump(tester, false);
      await _typeIn(tester, 'loan-setup-amount', r'$rent');
      expect(createEnabled(tester), isFalse);
      await _typeIn(tester, 'loan-setup-amount', '3000');
      await create(tester);
      expect(events.created.single.amount, Decimal.fromInt(3000));
      expect(events.createdJson.single.containsKey('amountExpr'), isFalse);
    });
  });
}
