// Where the variables manager is reached from (spec 012): the user menu,
// the timeline's More menu, FormulaField's Manage / Create actions, and
// the usages list's `?event=` link back into a timeline.
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/timeline/timeline_page.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/formula/formula_field.dart';
import 'package:budget_client/widgets/user_menu.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/formula_support.dart';
import '../support/fake_auth.dart';
import '../support/fake_categories.dart';
import 'manager_support.dart';

final _now = DateTime.now();
final _day = DateTime(_now.year, _now.month, _now.day);

class _Streams extends FakeStreams {
  _Streams(super.role);

  @override
  Future<BalanceSeries> balance(
    String streamId, {
    required DateTime from,
    required DateTime to,
  }) async => BalanceSeries(
    points: [
      for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1)))
        BalancePoint(date: d, closingBalance: Decimal.fromInt(1000)),
    ],
    occurrences: const [],
  );
}

class _Events extends EventRepository {
  _Events() : super(ApiClient());

  @override
  Future<List<BudgetEvent>> listForStream(String streamId) async => [
    BudgetEvent(
      id: 'rent',
      streamId: streamId,
      name: 'Rent',
      direction: EventDirection.debit,
      amount: Decimal.fromInt(1200),
      amountExpr: 'rent',
      startDate: _day.subtract(const Duration(days: 14)),
      recurrenceMode: RecurrenceMode.every,
      interval: 1,
      unit: RecurrenceUnit.weeks,
      endMode: EndMode.never,
      enabled: true,
    ),
  ];
}

Future<FakeVars> _timeline(
  WidgetTester tester, {
  Role role = Role.owner,
  String? openEventId,
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  // As the categories UI tests: the default test font is wide.
  tester.platformDispatcher.textScaleFactorTestValue = 0.75;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final vars = FakeVars(baseVars());
  final events = _Events();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        streamRepositoryProvider.overrideWithValue(_Streams(role)),
        eventRepositoryProvider.overrideWithValue(events),
        categoryRepositoryProvider.overrideWithValue(
          FakeCategoryRepository(events),
        ),
        variableRepositoryProvider.overrideWithValue(vars),
      ],
      child: MaterialApp(
        home: TimelinePage(streamId: 'acc', openEventId: openEventId),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return vars;
}

void main() {
  tearDown(() => ServerFeatures.variables = false);

  group('user menu', () {
    Future<FakeVars> pump(WidgetTester tester, {required bool on}) async {
      final vars = FakeVars(baseVars());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authRepositoryProvider.overrideWithValue(
              FakeAuthRepository(user: adminUser),
            ),
            variableRepositoryProvider.overrideWithValue(vars),
          ],
          child: MaterialApp(
            home: Scaffold(appBar: AppBar(actions: const [UserMenu()])),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The auth config sets the flag; the server's answer is what counts.
      ServerFeatures.variables = on;
      await tester.tap(k('user-menu'));
      await tester.pumpAndSettle();
      return vars;
    }

    testWidgets('Variables opens my own set, above Admin', (tester) async {
      final vars = await pump(tester, on: true);
      expect(k('menu-variables'), findsOneWidget);
      expect(
        tester.getTopLeft(k('menu-variables')).dy,
        lessThan(tester.getTopLeft(find.text('Admin').last).dy),
      );
      await tester.tap(k('menu-variables'));
      await tester.pumpAndSettle();
      expect(k('variables-manager'), findsOneWidget);
      expect(vars.reads, contains('mine'));
    });

    testWidgets('hidden without the server feature', (tester) async {
      await pump(tester, on: false);
      expect(k('menu-variables'), findsNothing);
      expect(find.text('Admin'), findsWidgets);
    });
  });

  group('timeline More menu', () {
    for (final role in [Role.owner, Role.viewer]) {
      testWidgets('Edit variables (${role.name}) opens the owner\'s set', (
        tester,
      ) async {
        ServerFeatures.variables = true;
        final vars = await _timeline(tester, role: role);
        await tester.tap(k('timeline-more'));
        await tester.pumpAndSettle();
        final cats = tester.getTopLeft(k('more-categories')).dy;
        expect(tester.getTopLeft(k('more-variables')).dy, greaterThan(cats));
        await tester.tap(k('more-variables'));
        await tester.pumpAndSettle();
        expect(k('variables-manager'), findsOneWidget);
        expect(vars.reads, contains('list acc'));
        expect(
          k('variable-new-row'),
          role == Role.owner ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('absent without the server feature', (tester) async {
      await _timeline(tester);
      await tester.tap(k('timeline-more'));
      await tester.pumpAndSettle();
      expect(k('more-categories'), findsOneWidget);
      expect(k('more-variables'), findsNothing);
    });
  });

  group('?event= link', () {
    for (final role in [Role.owner, Role.viewer]) {
      testWidgets('opens that event once (${role.name})', (tester) async {
        ServerFeatures.variables = true;
        await _timeline(tester, role: role, openEventId: 'rent');
        expect(k('editor-header'), findsOneWidget);
        await tester.tap(k('editor-close'));
        await tester.pumpAndSettle();
        expect(k('editor-header'), findsNothing);
        // A rebuild doesn't reopen it.
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(k('editor-header'), findsNothing);
      });
    }

    testWidgets('an unknown id does nothing', (tester) async {
      await _timeline(tester, openEventId: 'gone');
      expect(k('editor-header'), findsNothing);
    });
  });

  group('FormulaField actions', () {
    VariableScope scope(List<String?> opened, {bool manage = true}) =>
        VariableScope(
          streamId: 's1',
          variables: sampleScope().variables,
          canManage: manage,
          manage: manage
              ? (context, {createName}) async {
                  opened.add(createName);
                  return createName;
                }
              : null,
        );

    testWidgets('no match: Create "x"… opens the manager, inserts the name', (
      tester,
    ) async {
      final opened = <String?>[];
      final h = await pumpFormula(tester, scope: scope(opened));
      await typeText(tester, '2 * gym');
      expect(k('formula-create-variable'), findsOneWidget);
      expect(find.text('Create "gym"…'), findsOneWidget);
      await tester.tap(k('formula-create-variable'));
      await tester.pumpAndSettle();
      expect(opened, ['gym']);
      expect(h.controller.text, '2 * gym');
      expect(suggestions, findsNothing);
    });

    testWidgets('an invalid name offers Manage instead', (tester) async {
      final opened = <String?>[];
      await pumpFormula(tester, scope: scope(opened));
      await typeText(tester, r'$9');
      // `$9` is currency-like: no list at all.
      expect(suggestions, findsNothing);
      await typeText(tester, 'zz9');
      expect(k('formula-create-variable'), findsOneWidget);
    });

    testWidgets('no variables yet: Manage variables…', (tester) async {
      final opened = <String?>[];
      await pumpFormula(
        tester,
        scope: VariableScope(
          streamId: 's1',
          canManage: true,
          manage: (context, {createName}) async {
            opened.add(createName);
            return null;
          },
        ),
      );
      // Typing a word offers nothing (no variables to match); the picker
      // shows the empty state with Manage.
      await typeText(tester, 'r');
      expect(k('formula-manage-variables'), findsNothing);
      await tester.tap(k('editor-amount-var-picker'));
      await tester.pumpAndSettle();
      expect(k('formula-manage-variables'), findsOneWidget);
      await tester.tap(k('formula-manage-variables'));
      await tester.pumpAndSettle();
      expect(opened, [null]);
    });

    testWidgets('help menu offers Manage when allowed', (tester) async {
      final opened = <String?>[];
      await pumpFormula(tester, scope: scope(opened));
      await tester.tap(k('editor-amount-help'));
      await tester.pumpAndSettle();
      await tester.tap(k('formula-help-manage'));
      await tester.pumpAndSettle();
      expect(opened, [null]);
    });

    testWidgets('without canManage (editors, viewers): no actions', (
      tester,
    ) async {
      await pumpFormula(tester, scope: scope([], manage: false));
      await typeText(tester, 'gym');
      expect(k('formula-create-variable'), findsNothing);
      await tester.tap(k('editor-amount-help'));
      await tester.pumpAndSettle();
      expect(k('formula-help-manage'), findsNothing);
    });
  });
}
