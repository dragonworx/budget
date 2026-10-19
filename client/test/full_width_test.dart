import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:budget_client/features/timeline/balance_chart.dart';

void main() {
  test('plot and lanes span the full chart width', () {
    final l = ChartLayout.of(const Size(360, 600), 31);
    expect(l.plot.left, 0);
    expect(l.plot.width, 360);
    expect(l.monthBand.width, 360);
    expect(l.dayBand?.left, 0);
  });
}
