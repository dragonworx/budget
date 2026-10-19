import 'package:budget_client/widgets/money_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signs occurrence amounts by direction', () {
    expect(formatSignedAmount(1830), '+\$1,830');
    expect(formatSignedAmount(-22.99), '−\$22.99');
    expect(formatSignedAmount(-2650), '−\$2,650');
    expect(formatSignedAmount(0), '\$0.00');
  });

  test('uses compact formatting from a million', () {
    expect(formatSignedAmount(1360000), '+\$1.36M');
    expect(formatSignedAmount(-2500000), '−\$2.5M');
  });

  test('parses typed money input leniently', () {
    expect(parseMoneyInput('1,250.50').toString(), '1250.5');
    expect(parseMoneyInput(' A\$2 500 ').toString(), '2500');
    expect(parseMoneyInput('-120.5').toString(), '-120.5');
    expect(parseMoneyInput('\$-3').toString(), '-3');
    expect(parseMoneyInput('.5').toString(), '0.5');
    expect(parseMoneyInput('abc'), isNull);
    expect(parseMoneyInput('1.2.3'), isNull);
    expect(parseMoneyInput(''), isNull);
  });
}
