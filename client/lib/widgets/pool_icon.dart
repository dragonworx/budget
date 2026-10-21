import 'package:flutter/material.dart';

/// The pool glyph: an outlined bucket (pail with a handle), drawn on a
/// 24-unit grid with a 2-unit rounded stroke so it sits with Material's
/// rounded / outlined icons at 18–30px. Size and colour come from the
/// ambient [IconTheme] (like [Icon]) unless given.
class PoolIcon extends StatelessWidget {
  const PoolIcon({super.key, this.size, this.color, this.semanticLabel});
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? const Color(0xFFFFFFFF);
    final glyph = SizedBox.square(
      dimension: s,
      child: CustomPaint(painter: BucketPainter(c)),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: glyph)
        : Semantics(label: semanticLabel, child: glyph);
  }
}

/// Paints [PoolIcon]'s bucket; exposed for tests.
class BucketPainter extends CustomPainter {
  const BucketPainter(this.color);
  final Color color;

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
    // Handle: a loop over the rim, attached at the rim's ends.
    canvas.drawPath(
      Path()
        ..moveTo(5, 9.5)
        ..cubicTo(5, 2.5, 19, 2.5, 19, 9.5),
      stroke,
    );
    // Rim.
    canvas.drawLine(const Offset(3.5, 9.5), const Offset(20.5, 9.5), stroke);
    // Tapered body with a rounded base.
    canvas.drawPath(
      Path()
        ..moveTo(5, 9.5)
        ..lineTo(6.6, 19.2)
        ..quadraticBezierTo(6.9, 21, 8.7, 21)
        ..lineTo(15.3, 21)
        ..quadraticBezierTo(17.1, 21, 17.4, 19.2)
        ..lineTo(19, 9.5),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(BucketPainter old) => old.color != color;
}
