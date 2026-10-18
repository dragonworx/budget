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
}
