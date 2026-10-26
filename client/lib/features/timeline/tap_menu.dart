import 'dart:math' as math;
import 'dart:ui';

/// Where a lane's action menu of [menu] size goes for a tap at [tap], kept
/// fully inside [bounds] (the timeline view, already clear of the screen's
/// safe areas). Preferred: just below and right of the tap, so the finger
/// or pointer does not cover it; flipped left of the tap near the right
/// edge and above it near the bottom; then shifted (clamped) into
/// [bounds]. A menu larger than [bounds] keeps its top-left corner in it.
Offset placeTapMenu(Offset tap, Size menu, Rect bounds, {double gap = 8}) {
  var x = tap.dx;
  if (x + menu.width > bounds.right) x = tap.dx - menu.width;
  var y = tap.dy + gap;
  if (y + menu.height > bounds.bottom) y = tap.dy - gap - menu.height;
  x = math.max(bounds.left, math.min(x, bounds.right - menu.width));
  y = math.max(bounds.top, math.min(y, bounds.bottom - menu.height));
  return Offset(x, y);
}

/// Corner radius of the event action menu (the app's popup radius); its
/// lane-coloured header rounds its top corners to match.
const double dotMenuRadius = 12;
