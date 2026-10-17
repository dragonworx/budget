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
  test('floating y-scale buttons: 44px on phone, 32px on desktop', () {
    final phone = ChartLayout.of(const Size(360, 600), 31).yControls;
    expect(phone.width, 44);
    expect(phone.height, 88);
    expect(phone.left, greaterThanOrEqualTo(0));
    final desk = ChartLayout.of(const Size(1300, 700), 31);
    expect(desk.yControls.width, 32);
    expect(desk.yControls.center.dy, closeTo(desk.plot.center.dy, 0.01));
  });
}
