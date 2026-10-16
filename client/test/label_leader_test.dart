import 'dart:ui';

import 'package:budget_client/features/timeline/chart_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leader runs from nearest box point to the dot edge', () {
    final l = labelLeader(
      const Rect.fromLTWH(100, 0, 60, 30),
      const Offset(80, 60),
      4,
    )!;
    expect(l.$1, const Offset(100, 30)); // box corner nearest the dot
    final toCentre = (l.$2 - const Offset(80, 60)).distance;
    expect(toCentre, closeTo(5, 1e-9)); // radius + 1, not the centre
  });

  test('no leader when the label is adjacent or covers the dot', () {
    expect(
      labelLeader(const Rect.fromLTWH(10, 0, 40, 20), const Offset(30, 26), 3),
      isNull,
    );
    expect(
      labelLeader(const Rect.fromLTWH(0, 0, 40, 20), const Offset(20, 10), 3),
      isNull,
    );
  });
}
