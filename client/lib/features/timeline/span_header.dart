// The thin strip above the chart: the first and last visible days at its
// edges and, centred, the view's length in the words the long-press
// selection uses ([formatSpanDuration]).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../theme/app_theme.dart';
import 'chart_geometry.dart';
import 'duration_format.dart';

/// The chart's view: its left edge and width in days.
typedef VisibleView = ({DateTime start, double days});

/// The first and last calendar days at least partly in a view [days] wide
/// from [start] (the chart spans the whole width).
(DateTime, DateTime) visibleDayRange(DateTime start, double days) {
  final a = dayCoord(start);
  final first = dateFromDayCoord(a.floorToDouble());
  final last = dateFromDayCoord((a + days - 1e-6).floorToDouble());
  return (first, last.isBefore(first) ? first : last);
}

/// Edge date formats, longest first: the selection card's, then shorter
/// ones for narrow strips.
final List<DateFormat> _edgeFormats = [
  DateFormat('d MMM y'),
  DateFormat('d MMM yy'),
  DateFormat('d/M/yy'),
];

/// Height of the strip.
const double spanHeaderHeight = 22;

/// Listens to [view] itself, so a pan or zoom repaints only this strip.
class VisibleSpanHeader extends StatelessWidget {
  const VisibleSpanHeader({super.key, required this.view});

  final ValueListenable<VisibleView> view;

  @override
  Widget build(BuildContext context) {
    final base = (Theme.of(context).textTheme.labelSmall ?? const TextStyle())
        .copyWith(fontSize: 11, height: 1.2, letterSpacing: 0.1);
    final edge = base.copyWith(
      color: AppTheme.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final mid = base.copyWith(
      color: AppTheme.text,
      fontWeight: FontWeight.w600,
    );
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      key: const ValueKey('span-header'),
      height: spanHeaderHeight,
      child: LayoutBuilder(
        builder: (context, box) => ValueListenableBuilder<VisibleView>(
          valueListenable: view,
          builder: (context, v, _) {
            final (first, last) = visibleDayRange(v.start, v.days);
            final span = formatSpanDuration(
              first,
              last,
              precision: durationPrecisionFor(v.days),
            );
            double width(String s, TextStyle style) {
              final tp = TextPainter(
                text: TextSpan(text: s, style: style),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
                maxLines: 1,
              )..layout();
              final w = tp.width;
              tp.dispose();
              return w;
            }

            // The longest edge format that leaves the centred text room
            // (it needs both sides clear of the wider date).
            const gap = 10.0;
            final spanW = width(span, mid);
            late String l, r;
            late double edgeW;
            for (final f in _edgeFormats) {
              l = f.format(first);
              r = f.format(last);
              edgeW = width(l, edge) > width(r, edge)
                  ? width(l, edge)
                  : width(r, edge);
              if (2 * (edgeW + gap) + spanW <= box.maxWidth) break;
            }
            final side = (edgeW + gap).clamp(0.0, box.maxWidth / 2);
            Widget text(String s, TextStyle style, String key, TextAlign a) =>
                Text(
                  s,
                  key: ValueKey(key),
                  style: style,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  textAlign: a,
                );
            return Semantics(
              label: 'Showing $l to $r, $span',
              excludeSemantics: true,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: text(l, edge, 'span-header-start', TextAlign.left),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: text(r, edge, 'span-header-end', TextAlign.right),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: side),
                    child: Center(
                      child: text(
                        span,
                        mid,
                        'span-header-span',
                        TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
