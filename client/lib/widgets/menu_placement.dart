import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart';

/// Gap kept between a menu and the safe/visible area, and between a menu
/// and its anchor.
const double kMenuMargin = 8;

/// Preferred side of the anchor to place a menu or submenu.
enum MenuPlacement {
  /// A dropdown: below the anchor, flipping above if needed.
  below,

  /// A submenu: to the end (right in LTR), flipping to the start if needed.
  end,
}

/// Where [placeMenu] put the panel and the size it must take (height or
/// width may be capped so the panel can scroll inside the viewport).
class MenuPlacementResult {
  const MenuPlacementResult({
    required this.offset,
    required this.size,
    required this.placement,
    required this.capped,
  });

  /// Top-left of the menu, in the same coordinates as the anchor and
  /// viewport.
  final Offset offset;

  /// Size to give the menu. May be smaller than the wanted size when the
  /// panel has to scroll.
  final Size size;

  /// Side that was actually used.
  final MenuPlacement placement;

  /// True when the wanted size was larger than the space on the chosen
  /// side, so the menu must scroll (or otherwise shrink) to [size].
  final bool capped;

  Rect get rect => offset & size;
}

/// The rectangle a menu may occupy: the overlay (intersected with the
/// browser visual viewport on web), minus safe-area / keyboard insets and
/// [margin] (8px by default).
///
/// [overlaySize] is the overlay the menu will be inserted into (from
/// [RawMenuOverlayInfo.overlaySize] or [MediaQuery.sizeOf]).
Rect menuViewport({
  required Size overlaySize,
  EdgeInsets viewPadding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
  Rect? visualViewport,
  double margin = kMenuMargin,
}) {
  var rect = Offset.zero & overlaySize;
  final vis = visualViewport ?? visualViewportRect();
  if (vis != null) {
    final hit = rect.intersect(vis);
    if (hit.width > 0 && hit.height > 0) rect = hit;
  }
  final left = rect.left + viewPadding.left + margin;
  final top = rect.top + viewPadding.top + margin;
  final right = rect.right - viewPadding.right - margin;
  final bottom =
      rect.bottom -
      math.max(viewPadding.bottom, viewInsets.bottom) -
      margin;
  if (right <= left || bottom <= top) {
    // Degenerate insets: keep a 1px box so callers can still clamp.
    return Rect.fromLTWH(left, top, 1, 1);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// [menuViewport] using [context]'s [MediaQuery] and the visual viewport.
Rect menuViewportOf(BuildContext context, {double margin = kMenuMargin}) {
  final mq = MediaQuery.of(context);
  return menuViewport(
    overlaySize: mq.size,
    viewPadding: mq.viewPadding,
    viewInsets: mq.viewInsets,
    margin: margin,
  );
}

/// Places a menu of [wanted] size around [anchor] so the whole panel stays
/// inside [viewport] (already inset by safe areas and the 8px margin).
///
/// Dropdowns ([MenuPlacement.below]): open under the anchor; flip above
/// when there isn't enough room below (or when more room is above).
/// Submenus ([MenuPlacement.end]): open to the end (right in LTR); flip to
/// the start if that side has more room.
///
/// In both cases the panel is then shifted to stay inside the left/right
/// (and top/bottom) edges. If it still doesn't fit, its height (and width)
/// is capped to the viewport and the caller should scroll the contents.
MenuPlacementResult placeMenu({
  required Rect anchor,
  required Size wanted,
  required Rect viewport,
  MenuPlacement prefer = MenuPlacement.below,
  double gap = 4,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final maxW = math.max(0.0, viewport.width);
  final maxH = math.max(0.0, viewport.height);
  final w = math.min(wanted.width, maxW);
  final hWanted = wanted.height;

  late double x;
  late double y;
  late double h;
  late MenuPlacement used;

  if (prefer == MenuPlacement.end) {
    final endIsRight = textDirection == TextDirection.ltr;
    final spaceEnd = endIsRight
        ? viewport.right - anchor.right - gap
        : anchor.left - viewport.left - gap;
    final spaceStart = endIsRight
        ? anchor.left - viewport.left - gap
        : viewport.right - anchor.right - gap;
    final useEnd = spaceEnd >= w || spaceEnd >= spaceStart;
    used = MenuPlacement.end;
    if (useEnd) {
      x = endIsRight ? anchor.right + gap : anchor.left - gap - w;
    } else {
      x = endIsRight ? anchor.left - gap - w : anchor.right + gap;
    }
    // Vertically align to the top of the anchor, then flip/shift.
    h = math.min(hWanted, maxH);
    y = anchor.top;
    if (y + h > viewport.bottom) {
      y = anchor.bottom - h;
    }
    if (y < viewport.top) y = viewport.top;
    if (y + h > viewport.bottom) {
      h = math.max(0.0, viewport.bottom - y);
    }
  } else {
    final spaceBelow = viewport.bottom - anchor.bottom - gap;
    final spaceAbove = anchor.top - viewport.top - gap;
    final fitsBelow = hWanted <= spaceBelow;
    final fitsAbove = hWanted <= spaceAbove;
    final goBelow = fitsBelow || (!fitsAbove && spaceBelow >= spaceAbove);
    if (goBelow) {
      used = MenuPlacement.below;
      h = math.min(hWanted, math.max(0.0, spaceBelow));
      y = anchor.bottom + gap;
      if (y + h > viewport.bottom) {
        h = math.max(0.0, viewport.bottom - y);
      }
    } else {
      used = MenuPlacement.below; // still a dropdown, just flipped
      h = math.min(hWanted, math.max(0.0, spaceAbove));
      y = anchor.top - gap - h;
      if (y < viewport.top) {
        y = viewport.top;
        h = math.min(hWanted, math.max(0.0, anchor.top - gap - y));
      }
    }
    // Prefer the left edge of the anchor (LTR).
    x = anchor.left;
  }

  if (x + w > viewport.right) x = viewport.right - w;
  if (x < viewport.left) x = viewport.left;
  if (y + h > viewport.bottom) y = viewport.bottom - h;
  if (y < viewport.top) y = viewport.top;
  // Final cap if the viewport is smaller than the menu.
  final capW = math.min(w, math.max(0.0, viewport.right - x));
  final capH = math.min(h, math.max(0.0, viewport.bottom - y));
  final capped = capW + 0.5 < wanted.width || capH + 0.5 < wanted.height;
  return MenuPlacementResult(
    offset: Offset(x, y),
    size: Size(capW, capH),
    placement: used,
    capped: capped,
  );
}
