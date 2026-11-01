// The `$` autocomplete list (and the touch picker dialog) for FormulaField.
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'formula_style.dart';
import 'variable_scope.dart';

const double suggestionRowDesktop = 40;
const double suggestionRowTouch = 48;
const int suggestionMaxRows = 6;

/// The list itself: rows of `$name`, description, value and unit badge.
class FormulaSuggestionList extends StatelessWidget {
  const FormulaSuggestionList({
    super.key,
    required this.items,
    required this.prefix,
    required this.highlighted,
    required this.scope,
    required this.rowHeight,
    required this.maxHeight,
    required this.onPick,
    required this.onHover,
    this.scrollController,
  });

  final List<VariableValue> items;
  final String prefix;
  final int highlighted;
  final VariableScope scope;
  final double rowHeight;
  final double maxHeight;
  final ValueChanged<VariableValue> onPick;
  final ValueChanged<int> onHover;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = items.length;
    return Semantics(
      container: true,
      label: 'Variable suggestions, $n ${n == 1 ? 'result' : 'results'}',
      explicitChildNodes: true,
      child: Material(
        key: const ValueKey('formula-suggestions'),
        color: AppTheme.overlay,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppTheme.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: n == 0
              ? _empty(theme)
              : ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  shrinkWrap: true,
                  itemExtent: rowHeight,
                  itemCount: n,
                  itemBuilder: (context, i) => _row(theme, i),
                ),
        ),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    final none = scope.variables.isEmpty;
    final text = none ? 'No variables yet' : 'No variable named "\$$prefix"';
    return SizedBox(
      height: rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            key: const ValueKey('formula-suggestions-empty'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, int i) {
    final v = items[i];
    final lower = v.name.toLowerCase();
    final selected = i == highlighted;
    final body = theme.textTheme.bodyMedium;
    final desc = scope.descriptions[lower];
    final value = formatVariableValue(
      v,
      decimals: scope.displayDecimals[lower],
    );
    final unitName = v.unit.name;
    return Semantics(
      button: true,
      selected: selected,
      label: '\$${v.name}, ${spokenVariableValue(v)}, $unitName',
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => onHover(i),
        child: InkWell(
          key: ValueKey('formula-suggestion-${v.name}'),
          canRequestFocus: false,
          onTap: () => onPick(v),
          child: Container(
            color: selected ? AppTheme.accentSoft : null,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Flexible(
                  child: Text.rich(
                    _name(v.name, body),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    desc ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.textFaint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  value,
                  maxLines: 1,
                  style: body?.copyWith(color: AppTheme.textMuted),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.raised,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Text(
                    unitBadge(v.unit),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `$name` with the typed part in bold.
  TextSpan _name(String name, TextStyle? base) {
    final style = base?.copyWith(color: AppTheme.accent);
    final bold =
        style?.copyWith(fontWeight: FontWeight.w700) ??
        const TextStyle(fontWeight: FontWeight.w700);
    final p = prefix.toLowerCase();
    final at = p.isEmpty ? -1 : name.toLowerCase().indexOf(p);
    if (at < 0) return TextSpan(text: '\$$name', style: style);
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: '\$${name.substring(0, at)}'),
        TextSpan(text: name.substring(at, at + p.length), style: bold),
        TextSpan(text: name.substring(at + p.length)),
      ],
    );
  }
}

/// Touch: the picker as a dialog with a search box. Returns the choice.
Future<VariableValue?> showVariablePicker(
  BuildContext context, {
  required VariableScope scope,
}) => showDialog<VariableValue>(
  context: context,
  builder: (context) => _PickerDialog(scope: scope),
);

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({required this.scope});
  final VariableScope scope;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().replaceFirst(r'$', '');
    final items = rankCompletions(q, widget.scope.variables);
    final h = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      key: const ValueKey('formula-picker-dialog'),
      title: const Text('Insert a variable'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('formula-picker-search'),
              controller: _search,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: const InputDecoration(
                hintText: 'Search variables',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (items.isNotEmpty) Navigator.of(context).pop(items.first);
              },
            ),
            const SizedBox(height: 8),
            FormulaSuggestionList(
              items: items,
              prefix: q,
              highlighted: -1,
              scope: widget.scope,
              rowHeight: suggestionRowTouch,
              maxHeight: (h * 0.4).clamp(suggestionRowTouch, 6 * 48.0),
              onPick: (v) => Navigator.of(context).pop(v),
              onHover: (_) {},
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
