import 'package:flutter/material.dart';

/// Category-charts glyph (three bars of increasing height), painted on a
/// 24-unit grid so it can never be missing from an icon-font subset
/// (the same iPhone Safari issue as [ListGlyph]). Size and colour come
/// from the ambient [IconTheme], like [Icon].
class BarChartGlyph extends StatelessWidget {
  const BarChartGlyph({super.key, this.size, this.color});
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
        child: CustomPaint(painter: BarChartGlyphPainter(c)),
      ),
    );
  }
}

/// Paints [BarChartGlyph]; exposed for tests.
class BarChartGlyphPainter extends CustomPainter {
  const BarChartGlyphPainter(this.color);
  final Color color;

  /// Bar lefts and heights on the 24-unit grid (bottom-aligned at y=20).
  static const bars = [(5.0, 8.0), (11.0, 13.0), (17.0, 10.0)];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final (x, h) in bars) {
      canvas.drawLine(Offset(x, 20), Offset(x, 20 - h), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BarChartGlyphPainter old) => old.color != color;
}
