import 'package:budget_client/widgets/menu_placement.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const view = Rect.fromLTWH(8, 8, 304, 552); // 320×568 minus 8px margins

  Rect anchorAt({
    double l = 0,
    double t = 0,
    double w = 44,
    double h = 44,
  }) => Rect.fromLTWH(l, t, w, h);

  group('placeMenu dropdown', () {
    test('opens below the anchor when there is room', () {
      final r = placeMenu(
        anchor: anchorAt(l: 20, t: 20),
        wanted: const Size(160, 120),
        viewport: view,
      );
      expect(r.offset.dy, 20 + 44 + 4);
      expect(r.offset.dx, 20);
      expect(r.size, const Size(160, 120));
      expect(r.capped, isFalse);
    });

    test('flips above when there is not enough room below', () {
      final r = placeMenu(
        anchor: anchorAt(l: 20, t: 500),
        wanted: const Size(160, 120),
        viewport: view,
      );
      // 500+44+4+120 = 668 > 560 (view.bottom)
      expect(r.offset.dy + r.size.height, lessThanOrEqualTo(500 - 4));
      expect(r.offset.dy, greaterThanOrEqualTo(view.top));
      expect(r.size.height, 120);
      expect(r.capped, isFalse);
    });

    test('shifts left to stay inside the right edge', () {
      final r = placeMenu(
        anchor: anchorAt(l: 280, t: 20),
        wanted: const Size(160, 80),
        viewport: view,
      );
      expect(r.offset.dx + r.size.width, lessThanOrEqualTo(view.right));
      expect(r.offset.dx, greaterThanOrEqualTo(view.left));
      expect(r.size.width, 160);
    });

    test('shifts right to stay inside the left edge', () {
      final r = placeMenu(
        anchor: anchorAt(l: -10, t: 20),
        wanted: const Size(160, 80),
        viewport: view,
      );
      expect(r.offset.dx, view.left);
    });

    test('caps height and stays in the viewport when taller than both sides', () {
      final r = placeMenu(
        anchor: anchorAt(l: 20, t: 260),
        wanted: const Size(160, 800),
        viewport: view,
      );
      expect(r.capped, isTrue);
      expect(r.rect.top, greaterThanOrEqualTo(view.top));
      expect(r.rect.bottom, lessThanOrEqualTo(view.bottom));
      expect(r.rect.left, greaterThanOrEqualTo(view.left));
      expect(r.rect.right, lessThanOrEqualTo(view.right));
    });
  });

  group('placeMenu submenu', () {
    test('opens to the right when there is room', () {
      final r = placeMenu(
        anchor: anchorAt(l: 20, t: 40),
        wanted: const Size(160, 200),
        viewport: view,
        prefer: MenuPlacement.end,
      );
      expect(r.offset.dx, 20 + 44 + 4);
      expect(r.offset.dy, 40);
    });

    test('opens to the left when the right side is tight', () {
      final r = placeMenu(
        anchor: anchorAt(l: 250, t: 40),
        wanted: const Size(160, 200),
        viewport: view,
        prefer: MenuPlacement.end,
      );
      expect(r.offset.dx + r.size.width, lessThanOrEqualTo(250 - 4 + 0.5));
      expect(r.offset.dx, greaterThanOrEqualTo(view.left));
    });

    test('a low submenu shifts up to stay on screen', () {
      final r = placeMenu(
        anchor: anchorAt(l: 20, t: 500),
        wanted: const Size(160, 200),
        viewport: view,
        prefer: MenuPlacement.end,
      );
      expect(r.rect.bottom, lessThanOrEqualTo(view.bottom));
      expect(r.rect.top, greaterThanOrEqualTo(view.top));
    });
  });

  group('corners of a 320×568 screen', () {
    const wanted = Size(180, 160);
    final cases = <String, Rect>{
      'top-left': anchorAt(l: 8, t: 8),
      'top-right': anchorAt(l: 320 - 8 - 44, t: 8),
      'bottom-left': anchorAt(l: 8, t: 568 - 8 - 44),
      'bottom-right': anchorAt(l: 320 - 8 - 44, t: 568 - 8 - 44),
      'bottom-row': anchorAt(l: 216, t: 568 - 8 - 48),
    };
    for (final e in cases.entries) {
      test('${e.key} stays inside the padded viewport', () {
        final r = placeMenu(anchor: e.value, wanted: wanted, viewport: view);
        expect(r.rect.left, greaterThanOrEqualTo(view.left), reason: e.key);
        expect(r.rect.top, greaterThanOrEqualTo(view.top), reason: e.key);
        expect(r.rect.right, lessThanOrEqualTo(view.right), reason: e.key);
        expect(r.rect.bottom, lessThanOrEqualTo(view.bottom), reason: e.key);
      });
    }
  });

  group('menuViewport', () {
    test('subtracts safe-area insets and the 8px margin', () {
      final r = menuViewport(
        overlaySize: const Size(320, 568),
        viewPadding: const EdgeInsets.fromLTRB(0, 44, 0, 34),
        visualViewport: Rect.zero, // ignored: no intersection with a 0×0 box at origin? 
      );
      // A 0×0 visual viewport at origin intersects in a 0-width box, so
      // it should be ignored. Expect padding + margin only.
      expect(r.left, 8);
      expect(r.top, 44 + 8);
      expect(r.right, 320 - 8);
      expect(r.bottom, 568 - 34 - 8);
    });

    test('intersects the visual viewport (iOS browser chrome)', () {
      final r = menuViewport(
        overlaySize: const Size(320, 700),
        viewPadding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
        visualViewport: const Rect.fromLTWH(0, 40, 320, 500),
      );
      expect(r.top, 40 + 8);
      expect(r.bottom, 40 + 500 - 8);
    });

    test('the keyboard (viewInsets) shrinks the bottom', () {
      final r = menuViewport(
        overlaySize: const Size(320, 568),
        viewInsets: const EdgeInsets.only(bottom: 300),
      );
      expect(r.bottom, 568 - 300 - 8);
    });
  });
}
