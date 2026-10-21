import 'package:flutter/material.dart';

/// The Transactions list glyph (bulleted list: three dots, three lines),
/// drawn with a painter on a 24-unit grid to match Material's rounded list
/// icon. Painted rather than taken from the icon font so it can never be
/// missing from a font subset (e.g. a browser still holding an older
/// build's MaterialIcons file, which drew this button blank on iOS
/// Safari). Size and colour come from the ambient [IconTheme], like [Icon].
class ListGlyph extends StatelessWidget {
  const ListGlyph({super.key, this.size, this.color});
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
        child: CustomPaint(painter: ListGlyphPainter(c)),
      ),
    );
  }
}

/// Paints [ListGlyph]; exposed for tests.
class ListGlyphPainter extends CustomPainter {
  const ListGlyphPainter(this.color);
  final Color color;

  /// Row centres on the 24-unit grid.
  static const rows = [6.5, 12.0, 17.5];

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final dot = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final y in rows) {
      canvas.drawCircle(Offset(4.5, y), 1.5, dot);
      canvas.drawLine(Offset(9, y), Offset(20, y), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ListGlyphPainter old) => old.color != color;
}
