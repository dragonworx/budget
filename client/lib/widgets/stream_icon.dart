import 'package:flutter/material.dart';

/// The stream glyph: Designer's option B wave, without the baseline
/// or a "now" dot. Drawn on a 24-unit grid with a 2-unit rounded
/// stroke (the same weight at 16px; the stroke is not thinned). Size
/// and colour come from the ambient [IconTheme] (like [Icon]) unless
/// given.
///
/// Painted, not a font icon, so it shows on browsers that drop
/// Material glyphs (notably iPhone Chrome).
class StreamIcon extends StatelessWidget {
  const StreamIcon({super.key, this.size, this.color, this.semanticLabel});
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// Inside the 40px [IconTile].
  static const double tileSize = 20;

  /// Small / list contexts.
  static const double listSize = 16;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? const Color(0xFFFFFFFF);
    final glyph = SizedBox.square(
      dimension: s,
      child: CustomPaint(painter: StreamGlyphPainter(c)),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: glyph)
        : Semantics(label: semanticLabel, child: glyph);
  }
}

/// Paints [StreamIcon]'s single wave; exposed for tests.
///
/// The path is the hand-converted wave `d` from
/// `stream-icon-b-wave-timeline.svg` (viewBox 0 0 24 24, stroke 2,
/// round caps and joins), shifted down 1 unit so the wave is
/// vertically centred in the box once the SVG's baseline is dropped.
class StreamGlyphPainter extends CustomPainter {
  const StreamGlyphPainter(this.color);
  final Color color;

  /// Wave: `M3 11c1.5-4.5 4.5-4.5 6 0s4.5 4.5 6 0 4.5-4.5 6 0`
  /// with every Y +1 so the curve centres on y = 12.
  static Path wavePath() => Path()
    ..moveTo(3, 12)
    ..cubicTo(4.5, 7.5, 7.5, 7.5, 9, 12)
    ..cubicTo(10.5, 16.5, 13.5, 16.5, 15, 12)
    ..cubicTo(16.5, 7.5, 19.5, 7.5, 21, 12);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(wavePath(), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(StreamGlyphPainter old) => old.color != color;
}
