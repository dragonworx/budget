// Where a variable is used, and which fields need attention (spec 012):
// a list grouped by stream; tapping a row returns it so the manager can
// open that event or jump to that variable.
import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/repositories.dart';
import '../../theme/app_theme.dart';
import '../../widgets/formula/formula_style.dart';
import 'variable_impact.dart';

typedef UsageRows = ({List<VariableUsage> rows, int hidden});

/// "Where $rent is used" (or, with [title] / [message], "$rent is in
/// use": change these first). Resolves to the row tapped, if any.
Future<VariableUsage?> showVariableUsages(
  BuildContext context, {
  required VariableRepository repository,
  required String variableId,
  required String name,
  String? streamId,
  String? title,
  String? message,
  bool Function(String lowerName)? isKnown,
  Map<String, String> variableUnits = const {},
}) => _show(
  context,
  key: const ValueKey('variable-usages'),
  title: title ?? 'Where \$$name is used',
  message: message,
  isKnown: isKnown,
  variableUnits: variableUnits,
  load: () async {
    final r = await repository.usages(variableId, streamId: streamId);
    return (
      rows: usagesFromJson(r['usages']),
      hidden: (r['hidden'] as num?)?.toInt() ?? 0,
    );
  },
);

/// The fields whose formulas no longer work (D8), with each one's error.
Future<VariableUsage?> showVariableAttention(
  BuildContext context, {
  required VariableRepository repository,
  String? streamId,
  bool Function(String lowerName)? isKnown,
}) => _show(
  context,
  key: const ValueKey('variable-attention-list'),
  title: 'Fields that need attention',
  message:
      'Their formulas no longer work; they keep their last value until '
      'fixed. Tap one to open it.',
  isKnown: isKnown,
  load: () async {
    final r = await repository.attention(streamId: streamId);
    return (rows: usagesFromJson(r['items']), hidden: 0);
  },
);

Future<VariableUsage?> _show(
  BuildContext context, {
  required Key key,
  required String title,
  String? message,
  required Future<UsageRows> Function() load,
  bool Function(String lowerName)? isKnown,
  Map<String, String> variableUnits = const {},
}) {
  final width = MediaQuery.sizeOf(context).width;
  return showDialog<VariableUsage>(
    context: context,
    builder: (_) => Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: width < 600 ? 8 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: VariableUsagesList(
          key: key,
          title: title,
          message: message,
          load: load,
          isKnown: isKnown ?? (_) => true,
          variableUnits: variableUnits,
        ),
      ),
    ),
  );
}

class VariableUsagesList extends StatefulWidget {
  const VariableUsagesList({
    super.key,
    required this.title,
    required this.load,
    required this.isKnown,
    this.message,
    this.variableUnits = const {},
  });

  final String title;
  final String? message;
  final Future<UsageRows> Function() load;
  final bool Function(String lowerName) isKnown;
  final Map<String, String> variableUnits;

  @override
  State<VariableUsagesList> createState() => _VariableUsagesListState();
}

class _VariableUsagesListState extends State<VariableUsagesList> {
  late Future<UsageRows> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 420;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: AppTheme.textMuted,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 12 : 20, 14, narrow ? 4 : 10, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title, style: theme.textTheme.titleLarge),
              ),
              IconButton(
                key: const ValueKey('variable-usages-close'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (widget.message != null)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 10),
              child: Text(
                widget.message!,
                key: const ValueKey('variable-usages-message'),
                style: muted,
              ),
            ),
          Flexible(
            child: FutureBuilder<UsageRows>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Couldn\'t load them: ${friendlyError(snap.error!)}',
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            setState(() => _future = widget.load()),
                        child: const Text('Retry'),
                      ),
                    ],
                  );
                }
                final data = snap.data;
                if (data == null) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _list(theme, data, muted);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(ThemeData theme, UsageRows data, TextStyle? muted) {
    final rows = data.rows;
    if (rows.isEmpty && data.hidden == 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Not used anywhere yet.',
          key: const ValueKey('variable-usages-empty'),
          style: muted,
        ),
      );
    }
    // Variables first (no stream), then by stream in the server's order.
    final groups = <String, List<(int, VariableUsage)>>{};
    for (var i = 0; i < rows.length; i++) {
      final u = rows[i];
      final g = u.entity == 'variable'
          ? 'Variables'
          : (u.streamName ?? 'Stream');
      groups.putIfAbsent(g, () => []).add((i, u));
    }
    final ordered = [
      if (groups.containsKey('Variables')) 'Variables',
      for (final g in groups.keys)
        if (g != 'Variables') g,
    ];
    final header = muted?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 6, bottom: 4),
      child: Column(
        key: const ValueKey('variable-usages-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in ordered) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(g.toUpperCase(), style: header),
            ),
            const Divider(height: 1),
            for (final (i, u) in groups[g]!) ...[
              _row(theme, i, u, muted),
              const Divider(height: 1),
            ],
          ],
          if (data.hidden > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '+${data.hidden} in streams you can\'t see',
                key: const ValueKey('variable-usages-hidden'),
                style: muted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, int i, VariableUsage u, TextStyle? muted) {
    final value = usageValue(u, u.value, variableUnits: widget.variableUnits);
    final expr = u.expr;
    return InkWell(
      key: ValueKey('variable-usage-$i'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => Navigator.of(context).pop(u),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    usageLabel(u),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (value.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppTheme.textFaint,
                ),
              ],
            ),
            if (expr != null && expr.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(
                  styledFormula(expr, muted, widget.isKnown),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (u.error != null && u.error!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  u.error!,
                  style: muted?.copyWith(color: AppTheme.warning),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
