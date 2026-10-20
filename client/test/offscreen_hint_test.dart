import 'package:budget_client/features/timeline/balance_chart.dart';
import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no "up to … above" chip when balances in view exceed the top', () {
    // Highs clipped above the range: nothing (the ▲ max marker names it).
    expect(offscreenHint(const BalanceExtents(100, 19800), 0), isNull);
    expect(offscreenHint(const BalanceExtents(0, 5000), 0), isNull);
  });

  test('the "down to … below" chip stays for clipped lows', () {
    final hint = offscreenHint(const BalanceExtents(-420, 900), 0);
    expect(hint, startsWith('▼ down to'));
    expect(hint, endsWith('below'));
    expect(hint, isNot(contains('up to')));
  });
}
