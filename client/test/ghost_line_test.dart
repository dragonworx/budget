import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/ghost_line.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

BalancePoint _p(int day, String v) => BalancePoint(
  date: DateTime(2026, 10, day),
  closingBalance: Decimal.parse(v),
);

void main() {
  test('steps start at the opening of from and change at the day edge', () {
    final steps = ghostSteps([
      _p(18, '1000'),
      _p(19, '1100'),
      _p(20, '1100'),
      _p(21, '1250'),
    ], from: DateTime(2026, 10, 19));
    // The carried 1000 is replaced on the first day: no zero-width step.
    expect(steps.length, 2);
    expect(steps[0].value, 1100);
    expect(steps[0].start, DateTime(2026, 10, 19));
    expect(steps[0].end, DateTime(2026, 10, 21));
    expect(steps[1].value, 1250);
    expect(steps[1].end, DateTime(2026, 10, 22));
  });

  test('no points gives no steps', () {
    expect(ghostSteps(const []), isEmpty);
  });
}
