import 'package:budget_client/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('insights parse lowest and runway dates', () {
    final i = BalanceInsights.fromJson({
      'lowest': {'date': '2026-11-03', 'balance': '850.00'},
      'alertDate': '2027-03-01',
      'zeroDate': null,
      'days': 365,
      'horizonDays': 1825,
    });
    expect(i.lowestBalance, 850);
    expect(i.lowestDate, DateTime(2026, 11, 3));
    expect(i.alertDate, DateTime(2027, 3, 1));
    expect(i.zeroDate, isNull);
  });
}
