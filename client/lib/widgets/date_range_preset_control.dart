import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../features/timeline/date_range.dart';
import '../theme/app_theme.dart';
import 'app_menu_anchor.dart';

/// Compact dropdown for the shared date range. The menu lists only the
/// six named presets; Custom is only the closed label when the current
/// dates do not match one. Optional muted dates sit beside the label
/// when there is room, and are dropped first at tight widths.
class DateRangePresetControl extends StatelessWidget {
  const DateRangePresetControl({
    super.key,
    required this.range,
    required this.onChanged,
    this.showDates = true,
  });

  final DateRange range;
  final ValueChanged<DateRange> onChanged;

  /// When false, only the preset name is shown (no date suffix).
  final bool showDates;

  @override
  Widget build(BuildContext context) {
    final label = range.preset.label;
    final dates = _dateSuffix(range);
    return LayoutBuilder(
      builder: (context, c) {
        final style = Theme.of(context).textTheme.bodyMedium;
        final muted = style?.copyWith(color: AppTheme.textMuted);
        final suffix = dates == null ? '' : '  $dates';
        final fullW = _textWidth('$label$suffix', style);
        final bounded = c.maxWidth.isFinite;
        final show =
            showDates && dates != null && bounded && c.maxWidth >= fullW + 22;
        final text = Text.rich(
          TextSpan(
            children: [
              TextSpan(text: label, style: style),
              if (show) TextSpan(text: suffix, style: muted),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        );
        return AppMenuAnchor(
          key: const ValueKey('date-range-preset'),
          menuChildren: [
            for (final p in DateRangePreset.menu)
              MenuItemButton(
                onPressed: () => onChanged(DateRange.fromPreset(p)),
                trailingIcon: range.preset == p
                    ? const Icon(Icons.check_rounded, size: 18)
                    : null,
                child: Text(p.label),
              ),
          ],
          builder: (context, controller, _) => Semantics(
            button: true,
            label: 'Date range',
            value: label,
            child: Tooltip(
              message: 'Date range',
              child: InkWell(
                onTap: () => controller.isOpen
                    ? controller.close()
                    : controller.open(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: bounded
                        ? MainAxisSize.max
                        : MainAxisSize.min,
                    children: [
                      if (bounded) Expanded(child: text) else text,
                      const SizedBox(width: 2),
                      const Icon(Icons.expand_more_rounded, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String? _dateSuffix(DateRange range) {
    if (range.isAllTime) return null;
    final start = range.start, end = range.end;
    if (start == null || end == null) return null;
    final fmt = DateFormat('d MMM y');
    if (start == end) return fmt.format(start);
    return '${fmt.format(start)}–${fmt.format(end)}';
  }

  static double _textWidth(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }
}
