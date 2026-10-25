import 'package:budget_client/app.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_streams.dart';
import 'support/fake_auth.dart';

void main() {
  testWidgets('BudgetApp builds when signed in, branded Budgie', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: adminUser),
          ),
          streamRepositoryProvider.overrideWithValue(FakeStreamRepository()),
        ],
        child: const BudgetApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('brand-navbar')), findsOneWidget);
    expect(find.bySemanticsLabel('Budgie'), findsOneWidget);
    expect(find.text('Budget'), findsNothing);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'Budgie',
    );
  });
}
