// The breakdown of one group marker at coarse zoom (spec 006 §5, §7): the
// period, exact totals in cents, the period's balances and every event's
// line. Hover card on pointer devices; bottom sheet on touch.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import 'chart_geometry.dart';
import 'clusters.dart';

typedef BreakdownLine = ({String name, int count, int cents});

/// What the breakdown shows, built from a bin's cached totals; the event
/// lines beyond the top 3 are computed here, for this one bin only.
class GroupBreakdown {
  GroupBreakdown({
    required this.bin,
    required this.period,
    required this.lines,
    required this.streams,
    this.opening,
    this.closing,
    this.min,
    this.max,
  });

  final GroupBin bin;
  final String period;
  final List<BreakdownLine> lines;

  /// Combined view: one line per stream (empty otherwise).
  final List<BreakdownLine> streams;
  final double? opening, closing, min, max;
}

GroupBreakdown buildGroupBreakdown(
  GroupClusters clusters,
  GroupBin bin,
  PointIndex ix, {
  required String Function(String eventId) nameOf,
  String Function(String? streamId)? streamName,
}) {
  final us0 = bin.start.microsecondsSinceEpoch;
  final us1 = bin.end.microsecondsSinceEpoch;
  final before = ix.lowerBound(us0) - 1;
  final lo = ix.lowerBound(us0), hi = ix.lowerBound(us1);
  final ext = lo < hi ? ix.rangeExtents(lo, hi) : null;
  final streams = <String?, (int, int)>{};
  if (streamName != null) {
    for (var k = bin.from; k < bin.to; k++) {
      final o = clusters.at(k);
      if (o.skipped || o.netted || isInterest(o)) continue;
      final e = streams[o.streamId];
      final c = clusters.cents[k];
      streams[o.streamId] = e == null ? (1, c) : (e.$1 + 1, e.$2 + c);
    }
  }
  return GroupBreakdown(
    bin: bin,
    period: binLabel(bin.period, bin.key),
    lines: [
      for (final l in clusters.linesOf(bin))
        (name: nameOf(l.eventId), count: l.count, cents: l.cents),
    ],
    streams: streams.length < 2
        ? const []
        : [
            for (final MapEntry(:key, :value) in streams.entries)
              (name: streamName!(key), count: value.$1, cents: value.$2),
          ],
    opening: before >= 0 ? ix.values[before] : null,
    closing: hi > 0 ? ix.values[hi - 1] : null,
    min: ext?.min,
    max: ext?.max,
  );
}

/// Exact to the cent, signed: "−$1,234.56".
String exactMoneyText(int cents) {
  final text = NumberFormat.currency(
    symbol: moneySymbol,
    decimalDigits: 2,
  ).format(cents.abs() / 100);
  return cents < 0
      ? '−$text'
      : cents > 0
      ? '+$text'
      : text;
}

String _balance(double? v) => v == null
    ? '—'
    : NumberFormat.currency(symbol: moneySymbol, decimalDigits: 2).format(v);

/// The breakdown's content; [onZoomIn] shows the period at about a third
/// of the plot. [touch]: rows and buttons at least 44 pt tall.
class GroupBreakdownView extends StatelessWidget {
  const GroupBreakdownView({
    super.key,
    required this.data,
    this.onZoomIn,
    this.touch = false,
  });

  final GroupBreakdown data;
  final VoidCallback? onZoomIn;
  final bool touch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = data.bin;
    final small = theme.textTheme.bodySmall ?? const TextStyle();
    final rowH = touch ? 44.0 : 22.0;
    Widget row(String label, String value, {Color? color, Key? key}) =>
        SizedBox(
          key: key,
          height: rowH,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: small.copyWith(color: AppTheme.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                value,
                style: small.copyWith(
                  color: color ?? AppTheme.text,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
    Color signed(int c) => c < 0
        ? AppTheme.debitColor
        : c > 0
        ? AppTheme.creditColor
        : AppTheme.text;
    final items = groupCountText(b.count);
    return Column(
      key: const ValueKey('group-breakdown'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          data.period,
          key: const ValueKey('group-breakdown-period'),
          style: (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          '$items ${b.count == 1 ? 'item' : 'items'} · grouped',
          style: small.copyWith(color: AppTheme.textMuted),
        ),
        const SizedBox(height: 6),
        row(
          'Net',
          exactMoneyText(b.netCents),
          color: signed(b.netCents),
          key: const ValueKey('group-breakdown-net'),
        ),
        row(
          'Money in',
          exactMoneyText(b.creditCents),
          color: AppTheme.creditColor,
        ),
        row(
          'Money out',
          exactMoneyText(-b.debitCents),
          color: AppTheme.debitColor,
        ),
        if (b.skipped > 0)
          row('Skipped (not counted)', groupCountText(b.skipped)),
        if (b.interestCount > 0)
          row(
            'Loan interest (×${groupCountText(b.interestCount)})',
            exactMoneyText(b.interestCents),
            color: signed(b.interestCents),
          ),
        if (b.nettedCount > 0)
          row('Transfers between streams', groupCountText(b.nettedCount)),
        const Divider(height: 12),
        row('Opening balance', _balance(data.opening)),
        row('Closing balance', _balance(data.closing)),
        row('Lowest balance', _balance(data.min)),
        row('Highest balance', _balance(data.max)),
        if (data.streams.isNotEmpty) ...[
          const Divider(height: 12),
          for (final s in data.streams)
            row(
              '${s.name} ×${groupCountText(s.count)}',
              exactMoneyText(s.cents),
              color: signed(s.cents),
            ),
        ],
        if (onZoomIn != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: touch ? 48 : 32,
            child: FilledButton.tonalIcon(
              key: const ValueKey('group-breakdown-zoom'),
              onPressed: onZoomIn,
              icon: const Icon(Icons.zoom_in, size: 18),
              label: const Text('Zoom in'),
            ),
          ),
        ],
        if (data.lines.isNotEmpty) const Divider(height: 12),
        for (final l in data.lines)
          row(
            '${l.name} ×${groupCountText(l.count)}',
            exactMoneyText(l.cents),
            color: signed(l.cents),
          ),
      ],
    );
  }
}

/// Touch: the breakdown as a bottom sheet (scrolls when long).
Future<void> showGroupBreakdownSheet(
  BuildContext context,
  GroupBreakdown data, {
  required VoidCallback onZoomIn,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: GroupBreakdownView(
          data: data,
          touch: true,
          onZoomIn: () {
            Navigator.of(context).pop();
            onZoomIn();
          },
        ),
      ),
    ),
  ),
);

/// Pointer hover: the breakdown in a compact card (top 3 lines + rest).
class GroupBreakdownCard extends StatelessWidget {
  const GroupBreakdownCard({super.key, required this.data});
  final GroupBreakdown data;

  @override
  Widget build(BuildContext context) {
    final shown = data.lines.length <= 4
        ? data
        : GroupBreakdown(
            bin: data.bin,
            period: data.period,
            streams: data.streams,
            opening: data.opening,
            closing: data.closing,
            min: data.min,
            max: data.max,
            lines: [
              ...data.lines.take(3),
              (
                name: '${data.lines.length - 3} more events',
                count: data.lines.skip(3).fold(0, (a, l) => a + l.count),
                cents: data.lines.skip(3).fold(0, (a, l) => a + l.cents),
              ),
            ],
          );
    return Material(
      key: const ValueKey('group-breakdown-card'),
      color: AppTheme.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: SizedBox(width: 240, child: GroupBreakdownView(data: shown)),
      ),
    );
  }
}

/// An exact marker (lowest / highest in view, alert breach / recovery):
/// its day and the balance that day, never grouped.
class ExactMarkerView extends StatelessWidget {
  const ExactMarkerView({
    super.key,
    required this.name,
    required this.day,
    required this.value,
  });

  final String name;
  final DateTime day;
  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('exact-marker'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          DateFormat('EEE d MMM y').format(day),
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textMuted),
        ),
        const SizedBox(height: 4),
        Text(
          'Balance ${_balance(value)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class ExactMarkerCard extends StatelessWidget {
  const ExactMarkerCard({
    super.key,
    required this.name,
    required this.day,
    required this.value,
  });

  final String name;
  final DateTime day;
  final double value;

  @override
  Widget build(BuildContext context) => Material(
    color: AppTheme.surface,
    elevation: 6,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: ExactMarkerView(name: name, day: day, value: value),
    ),
  );
}

Future<void> showExactMarkerSheet(
  BuildContext context, {
  required String name,
  required DateTime day,
  required double value,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: SizedBox(
        width: double.infinity,
        child: ExactMarkerView(name: name, day: day, value: value),
      ),
    ),
  ),
);
