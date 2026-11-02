// The "Insert a variable" list and the autocomplete stay in sync with the
// owner's variables: a variable created anywhere (this stream's manager,
// another stream's, my own manager, another tab via a live event) shows
// up in an open editor's field without a reload.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/realtime_service.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/events/event_editor.dart';
import 'package:budget_client/features/variables/variables_manager.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/state/realtime_providers.dart';
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/formula_support.dart' show suggestion;
import '../support/fake_auth.dart';
import '../support/fake_categories.dart';
import 'manager_support.dart';

Finder k(String key) => find.byKey(ValueKey(key));
final _amount = k('editor-amount');

class _Events extends EventRepository {
  _Events() : super(ApiClient(baseUrl: 'http://x'));
  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [];
}

/// The partial name that opens the autocomplete for [name].
String _typed(String name) => name.substring(0, 3);

Future<void> _typeInAmount(WidgetTester tester, String text) async {
  await tester.showKeyboard(_amount);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
  await tester.pumpAndSettle();
}

/// An event editor in stream 'acc' with a button that opens the manager
/// for [managerStream] (null: my own variables).
Future<(FakeVars, ProviderContainer)> _pump(
  WidgetTester tester, {
  String? managerStream,
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  ServerFeatures.variables = true;
  final vars = FakeVars(baseVars());
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(
        FakeAuthRepository(user: adminUser),
      ),
      eventRepositoryProvider.overrideWithValue(_Events()),
      categoryRepositoryProvider.overrideWith(
        (ref) => FakeCategoryRepository(ref.watch(eventRepositoryProvider), [
          'Groceries',
        ]),
      ),
      variableRepositoryProvider.overrideWithValue(vars),
      streamRepositoryProvider.overrideWithValue(FakeStreams(Role.owner)),
    ],
  );
  addTearDown(c.dispose);
  // Live events go through the app's controller; signing in reads the
  // server's features, so turn formulas on after that.
  c.read(realtimeControllerProvider);
  await tester.runAsync(() => c.read(authProvider.future));
  ServerFeatures.variables = true;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  key: const ValueKey('open-manager'),
                  onPressed: () =>
                      showVariablesManager(context, streamId: managerStream),
                  child: const Text('Manage'),
                ),
                Expanded(
                  child: EventEditor(streamId: 'acc', onDone: (_) {}),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // The editor's list is loaded (and cached) before the new variable.
  await _typeInAmount(tester, _typed('rent'));
  expect(suggestion('rent'), findsOneWidget);
  await _typeInAmount(tester, '');
  return (vars, c);
}

Future<void> _createInManager(WidgetTester tester, String name) async {
  await tester.tap(k('open-manager'));
  await tester.pumpAndSettle();
  await tester.enterText(k('variable-new-name'), name);
  await tester.enterText(k('variable-new-value'), '7');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  await tester.tap(k('variables-close'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => ServerFeatures.variables = false);

  for (final (label, stream) in [
    ('this stream\'s manager', 'acc'),
    ('another stream\'s manager', 'other'),
    ('my own manager', null),
  ]) {
    testWidgets('created in $label: the amount autocomplete shows it', (
      tester,
    ) async {
      await _pump(tester, managerStream: stream);
      expect(suggestion('bonus'), findsNothing);
      await _createInManager(tester, 'bonus');
      await _typeInAmount(tester, _typed('bonus'));
      expect(suggestion('bonus'), findsOneWidget);
    });
  }

  testWidgets('a live variable event without a stream (another tab) '
      'refreshes every stream\'s list', (tester) async {
    final (vars, c) = await _pump(tester);
    vars.store['x1'] = vr('x1', 'bonus', '7');
    c
        .read(realtimeControllerProvider)
        .handle(
          ChangeEvent(
            id: 9,
            action: 'variable.created',
            subjectUserId: adminUser.id,
          ),
        );
    await tester.pumpAndSettle();
    await _typeInAmount(tester, _typed('bonus'));
    expect(suggestion('bonus'), findsOneWidget);
  });

  testWidgets('touch: the open "Insert a variable" picker updates live', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final (vars, c) = await _pump(tester, platform: TargetPlatform.iOS);
    await tester.showKeyboard(_amount);
    await tester.pumpAndSettle();
    final button = k('editor-amount-var-picker').evaluate().isNotEmpty
        ? k('editor-amount-var-picker')
        : k('editor-amount-key-picker');
    await tester.tap(button.first);
    await tester.pumpAndSettle();
    expect(k('formula-picker-dialog'), findsOneWidget);
    expect(suggestion('bonus'), findsNothing);
    vars.store['x1'] = vr('x1', 'bonus', '7');
    c.invalidate(variablesProvider('acc'));
    await tester.pumpAndSettle();
    expect(suggestion('bonus'), findsOneWidget);
    await tester.tap(suggestion('bonus'));
    await tester.pumpAndSettle();
    final text = tester
        .widget<EditableText>(
          find.descendant(of: _amount, matching: find.byType(EditableText)),
        )
        .controller
        .text;
    expect(text, contains('bonus'));
    expect(
      (tester
                  .widget<EditableText>(
                    find.descendant(
                      of: _amount,
                      matching: find.byType(EditableText),
                    ),
                  )
                  .controller
              as FormulaEditingController)
          .formula
          .error
          ?.code,
      isNot(FormulaErrorCode.unknownVariable),
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
