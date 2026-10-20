import 'package:budget_client/data/alert.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/features/timeline/selection_period.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('alert is strictly below the threshold (equal is not)', () {
    expect(belowAlert(0.0, 0.0), isFalse);
    expect(belowAlert(-0.01, 0.0), isTrue);
    expect(belowAlert(100.0, 100.0), isFalse);
    expect(belowAlert(99.99, 100.0), isTrue);
    expect(belowAlert(Decimal.zero, Decimal.zero), isFalse);
    expect(belowAlert(Decimal.parse('-0.01'), Decimal.zero), isTrue);
  });

  test('new pool at 0 with a 0 threshold: no alert day, lowest not red', () {
    final day = DateTime(2026, 10, 1);
    final s = summarizePeriod(
      series: BalanceSeries(
        points: [
          for (var i = 0; i < 30; i++)
            BalancePoint(
              date: day.add(Duration(days: i)),
              closingBalance: Decimal.zero,
            ),
        ],
      ),
      start: day,
      end: day.add(const Duration(days: 29)),
      seedDate: day,
      seedBalance: 0,
      threshold: 0,
    );
    expect(s.lowestBalance, 0);
    expect(s.alertDate, isNull);
    expect(belowAlert(s.lowestBalance!, 0.0), isFalse);
  });
}
