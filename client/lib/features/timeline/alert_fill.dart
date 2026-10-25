import 'dart:ui';

/// One flat run of the stepped balance line in pixels: [x0]..[x1] at
/// height [y] (the line's own y for that run's balance).
typedef FillPlateau = ({double x0, double x1, double y, bool low});

/// The balance fill split at the alert line.
///
/// The chart fills under the stepped balance line down to the plot bottom.
/// A run whose balance is fine ([FillPlateau.low] false) keeps its green
/// column ([safe]). A run below the alert gets the red treatment: [deficit]
/// is the band between the alert line and the balance line (how far below
/// the alert it is; its top edge is exactly the alert line), and [under]
/// is its column under the line (the faint red fill it always had).
///
/// The line is stepped (risers are vertical at day edges), so the balance
/// crosses the alert line only on a riser: [crossings] are those points,
/// at the riser's x and the alert line's y, one per crossing (down or up).
/// A run touching the alert (equal is not an alert) stays green.
class AlertFill {
  const AlertFill({
    required this.safe,
    required this.deficit,
    required this.under,
    required this.crossings,
  });

  final List<Rect> safe;
  final List<Rect> deficit;
  final List<Rect> under;
  final List<Offset> crossings;

  static double area(List<Rect> rects) =>
      rects.fold(0.0, (sum, r) => sum + r.width * r.height);
}

/// Splits [plateaus] (left to right, abutting) at [alertY] inside [plot].
/// [alertY] may lie off the plot (above: every low run's band starts at
/// the plot top; below: low runs are off the plot too). Nothing is
/// returned outside [plot].
AlertFill alertFillOf(
  List<FillPlateau> plateaus, {
  required double alertY,
  required Rect plot,
}) {
  final safe = <Rect>[];
  final deficit = <Rect>[];
  final under = <Rect>[];
  final crossings = <Offset>[];
  double clampY(double y) => y.clamp(plot.top, plot.bottom).toDouble();
  final bandTop = clampY(alertY);
  bool? wasLow;
  for (final p in plateaus) {
    final x0 = p.x0.clamp(plot.left, plot.right).toDouble();
    final x1 = p.x1.clamp(plot.left, plot.right).toDouble();
    if (wasLow != null &&
        wasLow != p.low &&
        alertY >= plot.top &&
        alertY <= plot.bottom &&
        x0 > plot.left &&
        x0 < plot.right) {
      crossings.add(Offset(x0, alertY));
    }
    wasLow = p.low;
    if (x1 <= x0) continue;
    final y = clampY(p.y);
    if (!p.low) {
      if (y < plot.bottom) safe.add(Rect.fromLTRB(x0, y, x1, plot.bottom));
      continue;
    }
    if (y > bandTop) deficit.add(Rect.fromLTRB(x0, bandTop, x1, y));
    if (y < plot.bottom) under.add(Rect.fromLTRB(x0, y, x1, plot.bottom));
  }
  return AlertFill(
    safe: safe,
    deficit: deficit,
    under: under,
    crossings: crossings,
  );
}
