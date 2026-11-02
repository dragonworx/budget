import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One button of an [EventTypeButtons] row.
class TypeButton<T> {
  const TypeButton({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
    this.key,
    this.enabled = true,
    this.note,
  });

  final T value;
  final String label;
  final IconData icon;

  /// The type's colour (see EventTypeColour): its icon and outline, and
  /// the tint when selected.
  final Color color;
  final Key? key;

  /// False: shown in the same style but not tappable.
  final bool enabled;

  /// Why it isn't tappable (or another hint), shown as its tooltip.
  final String? note;
}

/// How much of each button fits (the same for the whole row).
enum TypeButtonFit { iconAndLabel, label, icon }

/// The row's fit for [n] buttons in [width] (one rule everywhere).
TypeButtonFit typeButtonFit(double width, int n) {
  final per = (width - EventTypeButtons.gap * (n - 1)) / n;
  if (per >= 92) return TypeButtonFit.iconAndLabel;
  if (per >= 62) return TypeButtonFit.label;
  return TypeButtonFit.icon;
}

/// The event type buttons: the editor's type picker and the Events list's
/// type filter. Always one row of equal buttons; narrower rows drop the
/// icons, then the labels (icons with tooltips).
class EventTypeButtons<T> extends StatelessWidget {
  const EventTypeButtons({
    super.key,
    required this.buttons,
    required this.selected,
    required this.onTap,
  });

  static const double gap = 6;
  static const double height = 40;

  final List<TypeButton<T>> buttons;
  final Set<T> selected;

  /// Null: none tappable (read only, or a locked type).
  final ValueChanged<T>? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final fit = typeButtonFit(c.maxWidth, buttons.length);
        return Row(
          children: [
            for (final (i, b) in buttons.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(child: _button(context, b, fit)),
            ],
          ],
        );
      },
    );
  }

  Widget _button(BuildContext context, TypeButton<T> b, TypeButtonFit fit) {
    final on = selected.contains(b.value);
    final tap = onTap;
    final interactive = tap != null && b.enabled;
    final c = b.color;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(
        color: on ? c : c.withValues(alpha: 0.35),
        width: on ? 1.5 : 1,
      ),
    );
    final text = Text(
      b.label,
      maxLines: 1,
      softWrap: false,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: on ? c : AppTheme.textMuted,
        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    final icon = Icon(b.icon, size: 18, color: c);
    final child = switch (fit) {
      TypeButtonFit.icon => icon,
      TypeButtonFit.label => FittedBox(fit: BoxFit.scaleDown, child: text),
      TypeButtonFit.iconAndLabel => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [icon, const SizedBox(width: 6), text],
        ),
      ),
    };
    final tip = [if (fit == TypeButtonFit.icon) b.label, ?b.note].join(' · ');
    Widget out = Material(
      color: on ? c.withValues(alpha: 0.18) : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: interactive ? () => tap(b.value) : null,
        mouseCursor: interactive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(child: child),
          ),
        ),
      ),
    );
    if (tip.isNotEmpty) {
      out = Tooltip(
        message: tip,
        excludeFromSemantics: true,
        // A button that can't be tapped explains itself on tap.
        triggerMode: interactive ? null : TooltipTriggerMode.tap,
        child: out,
      );
    }
    return Semantics(
      key: b.key,
      container: true,
      button: true,
      selected: on,
      enabled: interactive,
      label: b.label,
      hint: b.note,
      excludeSemantics: true,
      child: out,
    );
  }
}
