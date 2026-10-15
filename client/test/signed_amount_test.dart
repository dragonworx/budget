import 'package:budget_client/widgets/money_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signs occurrence amounts by direction', () {
    expect(formatSignedAmount(1830, 'AUD'), '+A\$1,830');
    expect(formatSignedAmount(-22.99, 'AUD'), '−A\$22.99');
    expect(formatSignedAmount(-2650, 'USD'), '−\$2,650');
    expect(formatSignedAmount(0, 'AUD'), 'A\$0.00');
  });

  test('uses compact formatting from a million', () {
    expect(formatSignedAmount(1360000, 'AUD'), '+A\$1.36M');
    expect(formatSignedAmount(-2500000, 'AUD'), '−A\$2.5M');
  });
}
