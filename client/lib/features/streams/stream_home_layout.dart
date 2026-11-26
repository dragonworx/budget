import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../data/models.dart';
import '../timeline/stack_lanes.dart';
import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart'
    as page;
import '../../theme/app_theme.dart';
import '../../widgets/stream_icon.dart';

/// localStorage key: "list" or "grid". Absent = default by width.
const String kStreamHomeLayoutKey = 'streams.homeLayout';

const double kStreamListRowExtent = 56;
const double kStreamListRowWithAlert = 64;
const double kStreamSectionHeaderExtent = 44;

/// P8 typography, used on the Streams home.
const TextStyle kStreamNameStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  height: 20 / 15,
  leadingDistribution: TextLeadingDistribution.even,
  color: AppTheme.text,
);

const TextStyle kStreamMetaStyle = TextStyle(
  fontSize: 12,
  height: 16 / 12,
  color: AppTheme.cardMeta,
);

const TextStyle kStreamBodyStyle = TextStyle(
  fontSize: 14,
  height: 20 / 14,
  color: AppTheme.textMuted,
);

TextStyle streamCardBalanceStyle({required bool alert}) => TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w600,
  height: 1,
  color: alert ? AppTheme.debitColor : AppTheme.text,
  fontFeatures: const [FontFeature.tabularFigures()],
);

TextStyle streamListBalanceStyle({required bool alert}) => TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  height: 1,
  color: alert ? AppTheme.debitColor : AppTheme.text,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Saved layout, or null when the user has not picked one.
String? readStreamHomeLayout() {
  final v = page.localGet(kStreamHomeLayoutKey);
  return v == 'list' || v == 'grid' ? v : null;
}

void writeStreamHomeLayout(String value) {
  page.localSet(kStreamHomeLayoutKey, value);
}

/// List below 600dp wide and grid above it, unless the user has picked one.
bool streamHomeIsList(double width, String? saved) {
  if (saved == 'list') return true;
  if (saved == 'grid') return false;
  return width < 600;
}

/// A new stream's default colour: the least-used palette entry among
/// [used] hexes. Ties go to the earlier palette colour, unless a
/// [random] is given (then a random tied entry).
String pickStreamColor(Iterable<String> used, [math.Random? random]) {
  final uses = List<int>.filled(laneColors.length, 0);
  for (final hex in used) {
    final col = colorFromHex(hex);
    final i = col == null ? null : laneColorIndexOf(col);
    if (i != null) uses[i]++;
  }
  final least = uses.reduce(math.min);
  final pool = [
    for (var i = 0; i < uses.length; i++)
      if (uses[i] == least) i,
  ];
  final i = random == null ? pool.first : pool[random.nextInt(pool.length)];
  return colorToHex(laneColors[i]);
}

/// The stream's own colour, or a stable palette fallback from its id.
Color streamTintOf(BudgetStream stream) {
  final c = colorFromHex(stream.color);
  if (c != null) return c;
  return laneColors[stream.id.hashCode.abs() % laneColors.length];
}

/// 32dp (card) or 28dp (list) tile around the wave glyph, tinted [color].
class StreamGlyphTile extends StatelessWidget {
  const StreamGlyphTile({
    super.key,
    required this.size,
    required this.color,
    this.glyphSize = 20,
    this.tileKey,
  });

  final double size;
  final Color color;
  final double glyphSize;
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: tileKey,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: StreamIcon(
          key: const ValueKey('stream-icon'),
          size: glyphSize,
          color: color,
        ),
      ),
    );
  }
}

/// 16dp chip: 12px bell + "Alert < $0". Turns red with the balance when
/// the threshold is crossed, so the alert never relies on colour alone.
class StreamAlertChip extends StatelessWidget {
  const StreamAlertChip({super.key, required this.label, this.alert = false});

  final String label;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final color = alert ? AppTheme.debitColor : AppTheme.cardMeta;
    return Container(
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: alert ? AppTheme.debitSoft : AppTheme.overlay,
        borderRadius: BorderRadius.circular(6),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none_rounded, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seed line + optional alert chip. Drops the year when the date would
/// otherwise be ellipsised, so "30 Sep" stays readable at a fixed card height.
class SeedMetaRow extends StatefulWidget {
  const SeedMetaRow({
    super.key,
    required this.metaKey,
    required this.seedText,
    required this.seedDate,
    this.chip,
  });

  final Key metaKey;
  final String seedText;
  final DateTime seedDate;
  final Widget? chip;

  @override
  State<SeedMetaRow> createState() => _SeedMetaRowState();
}

class _SeedMetaRowState extends State<SeedMetaRow> {
  /// Set when the full "d MMM y" line overflows after layout, so we
  /// drop the year rather than ellipsize the month ("30 S…").
  bool _dropYear = false;

  @override
  void didUpdateWidget(SeedMetaRow old) {
    super.didUpdateWidget(old);
    if (old.seedText != widget.seedText || old.seedDate != widget.seedDate) {
      _dropYear = false;
    }
  }

  void _dropYearIfOverflowed() {
    if (!mounted || _dropYear) return;
    RenderParagraph? paragraph;
    void visit(Element e) {
      if (paragraph != null) return;
      final ro = e.renderObject;
      if (e.widget.key == widget.metaKey && ro is RenderParagraph) {
        paragraph = ro;
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    if (paragraph != null && paragraph!.didExceedMaxLines) {
      setState(() => _dropYear = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = DateFormat('d MMM y').format(widget.seedDate);
    final short = DateFormat('d MMM').format(widget.seedDate);
    final withYear = '${widget.seedText} · $full';
    final noYear = '${widget.seedText} · $short';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dropYearIfOverflowed();
      // The themed web font may land after the first layout.
      Future<void>.delayed(
        const Duration(milliseconds: 50),
        _dropYearIfOverflowed,
      );
    });

    final text = _dropYear || widget.chip != null ? noYear : withYear;
    return Row(
      children: [
        Text(
          text,
          key: widget.metaKey,
          style: kStreamMetaStyle,
          maxLines: 1,
          overflow: TextOverflow.visible,
          softWrap: false,
        ),
        if (widget.chip != null) ...[
          const SizedBox(width: 8),
          Expanded(child: widget.chip!),
        ],
      ],
    );
  }
}

/// 44px target in the section header: switches between list and grid.
class StreamLayoutToggle extends StatelessWidget {
  const StreamLayoutToggle({
    super.key,
    required this.list,
    required this.onChanged,
  });

  final bool list;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: list ? 'Show as grid' : 'Show as list',
      child: SizedBox(
        width: 44,
        height: 44,
        child: IconButton(
          key: const ValueKey('streams-layout-toggle'),
          tooltip: list ? 'Show as grid' : 'Show as list',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          visualDensity: VisualDensity.compact,
          onPressed: () => onChanged(!list),
          icon: Icon(
            list ? Icons.grid_view_rounded : Icons.view_list_rounded,
            size: 22,
            color: AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}
