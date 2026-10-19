import 'package:budget_client/app.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';

class _Projects implements ProjectRepository {
  @override
  Future<List<Project>> list() async => [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('BudgetApp builds when signed in', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(user: adminUser),
          ),
          projectRepositoryProvider.overrideWithValue(_Projects()),
        ],
        child: const BudgetApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Budget'), findsOneWidget);
  });
}
