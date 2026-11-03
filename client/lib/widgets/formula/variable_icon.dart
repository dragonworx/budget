import 'package:flutter/material.dart';

/// The one glyph for variables (a Σ): the field's "Insert a variable"
/// button, the keypad's variable key, the variables manager and the menus
/// that open it.
///
/// Painted rather than taken from the icon font, like [ListGlyph]: iPhone
/// Safari drew both earlier icon-font glyphs here (`data_object`, then
/// `functions_rounded`) as nothing while the same build drew them in every
/// other browser, so the key showed as a blank green square. A painted glyph
/// has no font to miss. Size and colour come from the ambient [IconTheme],
/// like [Icon].
class VariableGlyph extends StatelessWidget {
  const VariableGlyph({super.key, this.size, this.color});
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? const Color(0xFFFFFFFF);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: s,
        child: CustomPaint(painter: VariableGlyphPainter(c)),
      ),
    );
  }
}

/// Paints [VariableGlyph] on a 24-unit grid; exposed for tests.
class VariableGlyphPainter extends CustomPainter {
  const VariableGlyphPainter(this.color);
  final Color color;

  /// The Σ stroke: top bar, in to the middle point, out to the bottom bar.
  static const points = [
    Offset(17.5, 6),
    Offset(6.5, 6),
    Offset(12.5, 12),
    Offset(6.5, 18),
    Offset(17.5, 18),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(VariableGlyphPainter old) => old.color != color;
}
