import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('describes the visible span in words', () {
    expect(describeSpan(1), '1 day');
    expect(describeSpan(7), '7 days');
    expect(describeSpan(14), '2 weeks');
    expect(describeSpan(70), '10 weeks');
    expect(describeSpan(91), '3 months');
    expect(describeSpan(365), '12 months');
    expect(describeSpan(730), '2 years');
    expect(describeSpan(548), '18 months');
    expect(describeSpan(1100), '3 years');
    expect(describeSpan(1280), '3.5 years');
  });
}
