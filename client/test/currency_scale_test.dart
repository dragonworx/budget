import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:budget_client/widgets/stream_dialog.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('currencyScaleRange: zero a third up the plot', () {
    double zeroFrac(BalanceExtents r) => (0 - r.min) / (r.max - r.min);
    test('10 units tall when the data fits', () {
      final r = currencyScaleRange(100, 200, 500);
      expect(r.max - r.min, closeTo(1000, 1e-9));
      expect(zeroFrac(r), closeTo(1 / 3, 1e-9));
      expect(r.max, greaterThanOrEqualTo(500));
    });
    test('large positive data widens in whole units, zero stays put', () {
      final r = currencyScaleRange(10, 4000, 6000);
      expect(zeroFrac(r), closeTo(1 / 3, 1e-9));
      expect(r.max, greaterThan(6000));
      expect((r.max - r.min) % 10, closeTo(0, 1e-6));
    });
    test('large negative data: the min fits below zero', () {
      final r = currencyScaleRange(1000, -50000, -20000);
      expect(zeroFrac(r), closeTo(1 / 3, 1e-9));
      expect(r.min, lessThan(-50000));
    });
    test('both sides fit; no unit still anchors', () {
      final r = currencyScaleRange(100, -2000, 9000);
      expect(zeroFrac(r), closeTo(1 / 3, 1e-9));
      expect(r.min, lessThan(-2000));
      expect(r.max, greaterThan(9000));
      final z = currencyScaleRange(0, 0, 0);
      expect(zeroFrac(z), closeTo(1 / 3, 1e-9));
      expect(z.max - z.min, greaterThan(0));
    });
  });

  test('Stream json round-trips currencyScale, defaults to 100', () {
    final a = BudgetStream.fromJson({
      'id': 'a',
      'name': 'n',
      'currency': 'AUD',
      'seedBalance': '0',
      'seedDate': '2026-10-01',
    });
    expect(a.currencyScale, 100);
    final b = BudgetStream.fromJson({...a.toJson(), 'currencyScale': 1000});
    expect(b.currencyScale, 1000);
    expect(b.toPatchJson()['currencyScale'], 1000);
    expect(b.toCreateJson()['currencyScale'], 1000);
    // Streams have no currency: an older payload's field is ignored and
    // never sent back.
    for (final json in [b.toJson(), b.toCreateJson(), b.toPatchJson()]) {
      expect(json.containsKey('currency'), isFalse);
    }
  });

  testWidgets('edit dialog changes Currency Scale', (tester) async {
    final existing = BudgetStream(
      id: 'a1',
      name: 'Main',
      seedBalance: Decimal.zero,
      seedDate: DateTime(2026, 10, 16),
      lossThreshold: Decimal.zero,
      currencyScale: 1000,
    );
    late Future<BudgetStream?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => result = showStreamDialog(c, existing: existing),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Currency Scale'), findsOneWidget);
    expect(find.text('Thousands (\$1k)'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('currency-scale-10')).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stream-save')));
    await tester.pumpAndSettle();
    expect((await result)!.currencyScale, 10);
  });

  test('autoCurrencyScale fits the span in 9 units', () {
    expect(BudgetStream.autoCurrencyScale(0), 1);
    expect(BudgetStream.autoCurrencyScale(800), 100);
    expect(BudgetStream.autoCurrencyScale(3500), 1000);
    expect(BudgetStream.autoCurrencyScale(-42000), 10000);
    expect(BudgetStream.autoCurrencyScale(5e9), 1000000);
  });

  testWidgets('new stream: no Currency Scale field; saves Hundreds', (
    tester,
  ) async {
    late Future<BudgetStream?> result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => result = showStreamDialog(c),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(BudgetStream.defaultCurrencyScale, 100);
    // Scale is only offered by Edit stream (Stream settings).
    expect(find.text('Currency Scale'), findsNothing);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    // A big seed balance doesn't change it either.
    await tester.enterText(find.byKey(const ValueKey('stream-seed')), '90000');
    await tester.enterText(find.byKey(const ValueKey('stream-name')), 'N');
    await tester.tap(find.byKey(const ValueKey('stream-save')));
    await tester.pumpAndSettle();
    expect((await result)!.currencyScale, 100);
    expect((await result)!.toCreateJson()['currencyScale'], 100);
  });
}
