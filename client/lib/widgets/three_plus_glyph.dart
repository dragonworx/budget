import 'package:flutter/material.dart';

/// The "New event today" glyph: three equal plus signs in a triangle (one
/// on top, two below), painted on a 24-unit grid like [ListGlyph] so it can
/// never be missing from an icon-font subset. Size and colour come from the
/// ambient [IconTheme], like [Icon].
class ThreePlusGlyph extends StatelessWidget {
  const ThreePlusGlyph({super.key, this.size, this.color});
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
        child: CustomPaint(painter: ThreePlusPainter(c)),
      ),
    );
  }
}

/// Paints [ThreePlusGlyph]; exposed for tests.
class ThreePlusPainter extends CustomPainter {
  const ThreePlusPainter(this.color);
  final Color color;

  /// Plus centres on the 24-unit grid, and each arm's half-length.
  static const centres = [Offset(12, 6), Offset(6, 17.5), Offset(18, 17.5)];
  static const arm = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final line = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    for (final c in centres) {
      canvas.drawLine(c.translate(-arm, 0), c.translate(arm, 0), line);
      canvas.drawLine(c.translate(0, -arm), c.translate(0, arm), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ThreePlusPainter old) => old.color != color;
}
