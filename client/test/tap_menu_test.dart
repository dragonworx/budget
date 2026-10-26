import 'dart:ui';

import 'package:budget_client/features/timeline/tap_menu.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const bounds = Rect.fromLTWH(0, 0, 400, 800);
  const menu = Size(260, 170);

  void fits(Offset o, [Rect b = bounds]) {
    final r = o & menu;
    expect(r.left, greaterThanOrEqualTo(b.left));
    expect(r.top, greaterThanOrEqualTo(b.top));
    expect(r.right, lessThanOrEqualTo(b.right));
    expect(r.bottom, lessThanOrEqualTo(b.bottom));
  }

  test('below-right of the tap when it fits', () {
    final o = placeTapMenu(const Offset(50, 100), menu, bounds);
    expect(o, const Offset(50, 108));
  });

  test('near the right edge: flips left of the tap', () {
    final o = placeTapMenu(const Offset(390, 100), menu, bounds);
    expect(o.dx, 390 - 260);
    fits(o);
  });

  test('near the bottom edge: flips above the tap', () {
    final o = placeTapMenu(const Offset(50, 790), menu, bounds);
    expect(o.dy + menu.height, 790 - 8);
    fits(o);
  });

  test('near the left / top edges and in a narrow view: shifted inside', () {
    for (final tap in const [
      Offset(0, 0),
      Offset(200, 0),
      Offset(200, 799),
      Offset(399, 799),
      Offset(150, 400),
    ]) {
      fits(placeTapMenu(tap, menu, bounds));
    }
    // Narrow: neither side has room; it shifts to the left edge.
    const narrow = Rect.fromLTWH(10, 40, 300, 600);
    final o = placeTapMenu(const Offset(200, 300), menu, narrow);
    fits(o, narrow);
  });

  test('a view smaller than the menu keeps its top-left inside', () {
    const tiny = Rect.fromLTWH(20, 30, 100, 80);
    final o = placeTapMenu(const Offset(60, 60), menu, tiny);
    expect(o, const Offset(20, 30));
  });
}
