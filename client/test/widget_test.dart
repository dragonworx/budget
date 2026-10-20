import 'package:budget_client/app.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pools.dart';
import 'support/fake_auth.dart';

void main() {
  testWidgets('BudgetApp builds when signed in', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: adminUser),
          ),
          poolRepositoryProvider.overrideWithValue(FakePoolRepository()),
        ],
        child: const BudgetApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Budget'), findsOneWidget);
  });
}
