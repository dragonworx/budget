import 'package:flutter/material.dart';

/// The stream glyph: Designer's option A — a wave ending in a filled
/// "today" dot — drawn on a 24-unit grid with a 2-unit rounded stroke
/// (the same weight at 16px; the stroke is not thinned) and a filled
/// circle of radius 2. Size and colour come from the ambient
/// [IconTheme] (like [Icon]) unless given.
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

/// Paints [StreamIcon]'s wave-and-dot; exposed for tests.
///
/// Paths are the hand-converted `d` and circle from
/// `stream-icon-a-wave-now.svg` (viewBox 0 0 24 24, stroke 2, round
/// caps and joins; the dot is a filled circle with no stroke).
class StreamGlyphPainter extends CustomPainter {
  const StreamGlyphPainter(this.color);
  final Color color;

  /// Wave: `M2.5 17.5C4.5 11 7.5 10.5 9.5 14.5S14 19 16.5 10.5`
  static Path wavePath() => Path()
    ..moveTo(2.5, 17.5)
    ..cubicTo(4.5, 11, 7.5, 10.5, 9.5, 14.5)
    ..cubicTo(11.5, 18.5, 14, 19, 16.5, 10.5);

  /// Filled "today" dot: `<circle cx="19.5" cy="6.5" r="2">`.
  static const Offset dotCenter = Offset(19.5, 6.5);
  static const double dotRadius = 2;

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
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(dotCenter, dotRadius, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(StreamGlyphPainter old) => old.color != color;
}
