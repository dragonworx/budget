import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/widgets/account_dialog.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('currencyScaleRange', () {
    test('10 units tall, origin visible, data centred when it fits', () {
      final r = currencyScaleRange(100, 200, 500);
      expect(r.max - r.min, closeTo(1000, 1e-9));
      expect(r.min, lessThanOrEqualTo(0));
      expect(r.max, greaterThanOrEqualTo(500));
    });
    test('large positive data: window above zero', () {
      final r = currencyScaleRange(10, 4000, 6000);
      expect(r.min, -5);
      expect(r.max, 95);
    });
    test('large negative data: window below zero', () {
      final r = currencyScaleRange(1000, -50000, -20000);
      expect(r.min, -9500);
      expect(r.max, 500);
    });
  });

  test('Account json round-trips currencyScale, defaults to 100', () {
    final a = Account.fromJson({
      'id': 'a', 'name': 'n', 'currency': 'AUD',
      'seedBalance': '0', 'seedDate': '2026-10-01',
    });
    expect(a.currencyScale, 100);
    final b = Account.fromJson({...a.toJson(), 'currencyScale': 1000});
    expect(b.currencyScale, 1000);
    expect(b.toPatchJson()['currencyScale'], 1000);
    expect(b.toCreateJson()['currencyScale'], 1000);
    // Accounts have no currency: an older payload's field is ignored and
    // never sent back.
    for (final json in [b.toJson(), b.toCreateJson(), b.toPatchJson()]) {
      expect(json.containsKey('currency'), isFalse);
    }
  });

  testWidgets('edit dialog changes Currency Scale', (tester) async {
    final existing = Account(
      id: 'a1', name: 'Main',
      seedBalance: Decimal.zero, seedDate: DateTime(2026, 10, 16),
      lossThreshold: Decimal.zero, currencyScale: 1000,
    );
    late Future<Account?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => result =
              showAccountDialog(c, existing: existing),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Currency Scale'), findsOneWidget);
    expect(find.text('Thousands (\$1k)'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('currency-scale-10')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pumpAndSettle();
    expect((await result)!.currencyScale, 10);
  });

  test('autoCurrencyScale fits the span in 9 units', () {
    expect(Account.autoCurrencyScale(0), 1);
    expect(Account.autoCurrencyScale(800), 100);
    expect(Account.autoCurrencyScale(3500), 1000);
    expect(Account.autoCurrencyScale(-42000), 10000);
    expect(Account.autoCurrencyScale(5e9), 1000000);
  });

  testWidgets('new account defaults to Hundreds; a pick sticks',
      (tester) async {
    late Future<Account?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => result = showAccountDialog(c),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(Account.defaultCurrencyScale, 100);
    expect(find.text('Hundreds (\$100)'), findsOneWidget); // seed 0
    // The seed balance no longer changes it.
    await tester.enterText(find.byKey(const ValueKey('account-seed')), '3500');
    await tester.pumpAndSettle();
    expect(find.text('Hundreds (\$100)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('account-name')), 'N');
    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pumpAndSettle();
    expect((await result)!.currencyScale, 100);
    expect((await result)!.toCreateJson()['currencyScale'], 100);
  });

  testWidgets('new account: an explicit Currency Scale pick is kept',
      (tester) async {
    late Future<Account?> result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(
          onPressed: () => result = showAccountDialog(c),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('currency-scale-10')).last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('account-seed')), '90000');
    await tester.pumpAndSettle();
    expect(find.text('Tens (\$10)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('account-name')), 'N');
    await tester.tap(find.byKey(const ValueKey('account-save')));
    await tester.pumpAndSettle();
    expect((await result)!.currencyScale, 10);
  });
}
