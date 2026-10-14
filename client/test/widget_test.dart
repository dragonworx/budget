import 'package:budget_client/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BudgetApp builds', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BudgetApp()));
    expect(find.text('Budget Tool'), findsOneWidget);
  });
}
