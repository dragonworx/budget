import 'package:budget_server/domain/models.dart';
import 'package:budget_server/engine/balance_insights.dart';
import 'package:decimal/decimal.dart';
import 'package:test/test.dart';

BalancePoint _p(int day, String v) => BalancePoint(
    date: DateTime.utc(2026, 1, day), closingBalance: Decimal.parse(v));

void main() {
  final points = [
    _p(1, '500'),
    _p(2, '120'),
    _p(3, '80'),
    _p(4, '-20'),
    _p(5, '300'),
  ];

  test('lowest point, alert crossing and zero crossing', () {
    final i = BalanceInsights.of(points, threshold: 100);
    expect(i.lowestBalance, -20);
    expect(i.lowestDate, DateTime.utc(2026, 1, 4));
    expect(i.alertDate, DateTime.utc(2026, 1, 3));
    expect(i.zeroDate, DateTime.utc(2026, 1, 4));
  });

  test('lowestThrough limits only the lowest point', () {
    final i = BalanceInsights.of(points,
        threshold: 0, lowestThrough: DateTime.utc(2026, 1, 3));
    expect(i.lowestBalance, 80);
    expect(i.alertDate, DateTime.utc(2026, 1, 4));
  });

  test('never crossing leaves dates null', () {
    final i = BalanceInsights.of(points.take(2).toList(), threshold: 0);
    expect(i.alertDate, isNull);
    expect(i.zeroDate, isNull);
    expect(i.toJson()['lowest'], {'date': '2026-01-02', 'balance': '120.00'});
  });

  test('equal to the threshold is not an alert (strictly below only)', () {
    final flat = [for (var d = 1; d <= 5; d++) _p(d, '0')];
    final zero = BalanceInsights.of(flat, threshold: 0);
    expect(zero.alertDate, isNull, reason: '0 balance, 0 threshold');
    expect(zero.zeroDate, isNull);
    final i = BalanceInsights.of([_p(1, '100'), _p(2, '100'), _p(3, '99.99')],
        threshold: 100);
    expect(i.alertDate, DateTime.utc(2026, 1, 3));
  });
}
