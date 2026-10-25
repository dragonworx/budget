import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Titled group of fields on a tonal panel.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Material (not a decoration) so ListTiles inside keep their ink.
    return Material(
      color: AppTheme.raised,
      shape: RoundedRectangleBorder(
        borderRadius: AppTheme.radiusAll,
        side: const BorderSide(color: AppTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: AppTheme.textFaint),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 0.9,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textFaint,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Round tinted badge with an arrow: green in, red out.
class DirectionBadge extends StatelessWidget {
  const DirectionBadge({
    super.key,
    required this.credit,
    this.size = 32,
    this.muted = false,
  });

  final bool credit;
  final double size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted
        ? AppTheme.textFaint
        : (credit ? AppTheme.creditColor : AppTheme.debitColor);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size / 3),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Icon(
        credit ? Icons.south_west_rounded : Icons.north_east_rounded,
        size: size * 0.5,
        color: color,
      ),
    );
  }
}

/// Small keyboard key cap, e.g. for shortcut help.
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.overlay,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppTheme.borderStrong),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Opens [child] as a panel sliding in from the right edge (full width on
/// narrow screens). Esc or a click on the scrim closes it.
Future<T?> showSidePanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 480,
  String label = 'Panel',
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: label,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) {
      final screen = MediaQuery.sizeOf(context);
      final w = screen.width < 720 ? screen.width : width;
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: w,
          height: screen.height,
          child: Material(
            color: AppTheme.surface,
            shape: const Border(left: BorderSide(color: AppTheme.border)),
            elevation: 12,
            child: SafeArea(child: Builder(builder: builder)),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween(
          begin: const Offset(0.12, 0),
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}

/// Centred, width-limited page content with consistent gutters.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child, this.maxWidth = 1080});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Big page title with a muted subtitle and optional trailing actions.
class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.eyebrow,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final String? eyebrow;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      eyebrow!.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
                Text(
                  title,
                  style: theme.textTheme.headlineMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(subtitle!, style: theme.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
          for (final a in actions) ...[const SizedBox(width: 8), a],
        ],
      ),
    );
  }
}

/// Icon + title + message + optional action, centred.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon,
    this.glyph,
    required this.title,
    required this.message,
    this.action,
    this.error = false,
  }) : assert(icon != null || glyph != null);
  final IconData? icon;

  /// A custom icon widget (e.g. [StreamIcon]) instead of [icon].
  final Widget? glyph;
  final String title;
  final String message;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = error ? AppTheme.debitColor : AppTheme.accent;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tint.withValues(alpha: 0.3)),
                ),
                child: IconTheme(
                  data: IconThemeData(size: 30, color: tint),
                  child: Center(child: glyph ?? Icon(icon)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                message,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Tinted square icon tile used on list cards.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color = AppTheme.accent})
    : glyph = null;

  /// A tile around a custom icon widget (e.g. [StreamIcon]).
  const IconTile.glyph(
    Widget this.glyph, {
    super.key,
    this.color = AppTheme.accent,
  }) : icon = null;
  final IconData? icon;
  final Widget? glyph;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(10),
    ),
    child: IconTheme(
      data: IconThemeData(color: color, size: 22),
      child: Center(child: glyph ?? Icon(icon)),
    ),
  );
}

/// Small rounded label, e.g. a currency code.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: (color ?? AppTheme.textMuted).withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(
        color: (color ?? AppTheme.textMuted).withValues(alpha: 0.28),
      ),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color ?? AppTheme.textMuted,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    ),
  );
}
