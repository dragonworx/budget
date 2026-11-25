import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/auth_repository.dart';
import '../data/models.dart' show BudgetStream, ServerFeatures;
import '../features/categories/categories_manager.dart';
import '../features/timeline/shortcuts_help.dart';
import '../features/variables/variables_manager.dart';
import '../state/auth_providers.dart';
import '../state/providers.dart';
import '../state/realtime_providers.dart';
import '../theme/app_theme.dart';
import 'formula/variable_icon.dart';

class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, this.radius = 15});

  final AuthUser user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final pic = user.pictureUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppTheme.accent,
      foregroundImage: pic == null || pic.isEmpty ? null : NetworkImage(pic),
      onForegroundImageError: pic == null || pic.isEmpty ? null : (_, _) {},
      child: Text(
        user.initials,
        style: TextStyle(
          fontSize: radius * 0.8,
          color: AppTheme.onAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Avatar button in the app header: identity, then Variables, Categories,
/// Admin (admins only), Help and Sign out.
///
/// Renders nothing when signed out. [streamId] / [canEdit] are set on
/// the timeline so Categories and Variables open in that stream's
/// context (viewers get the view-only manager). On Streams home,
/// Categories uses the last-opened or first stream when one exists.
class UserMenu extends ConsumerWidget {
  const UserMenu({
    super.key,
    this.streamId,
    this.canEdit,
    this.showRealtimeDot = true,
    this.compact = false,
  });

  /// The open stream, if this menu sits on a timeline.
  final String? streamId;

  /// Edit rights on [streamId]; otherwise taken from the resolved stream.
  final bool? canEdit;

  /// The timeline already shows sync status on the brand mark.
  final bool showRealtimeDot;

  /// Tighter padding and a slightly smaller avatar on narrow headers.
  final bool compact;

  BudgetStream? _stream(WidgetRef ref) {
    if (!ref.exists(streamsProvider)) return null;
    final streams = ref.read(streamsProvider).valueOrNull ?? const [];
    if (streams.isEmpty) return null;
    final want = streamId ?? ref.read(streamsProvider.notifier).lastStreamId;
    for (final s in streams) {
      if (s.id == want) return s;
    }
    return streams.first;
  }

  bool _hasStream(WidgetRef ref) => streamId != null || _stream(ref) != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).valueOrNull?.user;
    if (user == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      key: const ValueKey('user-menu'),
      tooltip: user.email,
      offset: const Offset(0, 44),
      onSelected: (v) {
        switch (v) {
          case 'sign-out':
            ref.read(authProvider.notifier).signOut();
          case 'admin':
            GoRouter.of(context).go('/admin');
          case 'variables':
            showVariablesManager(context, streamId: streamId);
          case 'categories':
            final s = _stream(ref);
            final id = streamId ?? s?.id;
            if (id == null) return;
            showCategoriesManager(
              context,
              streamId: id,
              canEdit: canEdit ?? s?.role.canEdit ?? false,
            );
          case 'help':
            showShortcutsHelp(context);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Row(
            children: [
              UserAvatar(user: user, radius: 18),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      user.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      user.email,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (user.isAdmin) ...[
                      const SizedBox(height: 4),
                      Container(
                        key: const ValueKey('admin-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Admin',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        // The owner's variables (spec 012); read-only for editors and viewers
        // when opened with a streamId.
        if (ServerFeatures.variables)
          const PopupMenuItem<String>(
            key: ValueKey('menu-variables'),
            value: 'variables',
            child: Row(
              children: [
                VariableGlyph(size: 18),
                SizedBox(width: 10),
                Text('Variables'),
              ],
            ),
          ),
        // Everyone opens it (viewers read only); categories are shared by
        // all the owner's streams. Hidden when no stream can be resolved.
        if (_hasStream(ref))
          const PopupMenuItem<String>(
            key: ValueKey('menu-categories'),
            value: 'categories',
            child: Row(
              children: [
                CategoryMenuGlyph(size: 18),
                SizedBox(width: 10),
                Text('Categories'),
              ],
            ),
          ),
        if (user.isAdmin)
          const PopupMenuItem<String>(
            key: ValueKey('menu-admin'),
            value: 'admin',
            child: Row(
              children: [
                Icon(Icons.admin_panel_settings_outlined, size: 18),
                SizedBox(width: 10),
                Text('Admin'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          key: ValueKey('menu-help'),
          value: 'help',
          child: Row(
            children: [
              HelpMenuGlyph(size: 18),
              SizedBox(width: 10),
              Text('Help'),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          key: ValueKey('sign-out'),
          value: 'sign-out',
          child: Row(
            children: [
              Icon(Icons.logout_rounded, size: 18),
              SizedBox(width: 10),
              Text('Sign out'),
            ],
          ),
        ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showRealtimeDot) const RealtimeDot(),
            UserAvatar(user: user, radius: compact ? 13 : 15),
          ],
        ),
      ),
    );
  }
}

/// Painted tag mark for the Categories menu item. Icon-font glyphs have
/// gone missing on iPhone Chrome before; a CustomPaint has no font to miss.
class CategoryMenuGlyph extends StatelessWidget {
  const CategoryMenuGlyph({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? AppTheme.textMuted;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _CategoryMenuGlyphPainter(c)),
      ),
    );
  }
}

class _CategoryMenuGlyphPainter extends CustomPainter {
  const _CategoryMenuGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s * 0.09).clamp(1.2, 2.0)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.translate(s / 2, s / 2);
    canvas.rotate(-0.65);
    canvas.translate(-s / 2, -s / 2);
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.16, s * 0.30, s * 0.68, s * 0.44),
      Radius.circular(s * 0.10),
    );
    canvas.drawRRect(body, p);
    canvas.drawCircle(Offset(s * 0.32, s * 0.52), s * 0.055, p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CategoryMenuGlyphPainter old) =>
      old.color != color;
}

/// Painted "?" in a circle for the Help menu item. Icon-font glyphs have
/// gone missing on iPhone Chrome before; a CustomPaint has no font to miss.
class HelpMenuGlyph extends StatelessWidget {
  const HelpMenuGlyph({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? AppTheme.textMuted;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _HelpMenuGlyphPainter(c)),
      ),
    );
  }
}

class _HelpMenuGlyphPainter extends CustomPainter {
  const _HelpMenuGlyphPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = (s * 0.09).clamp(1.2, 2.0);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(s / 2, s / 2), s * 0.38, p);
    final q = Path()
      ..moveTo(s * 0.38, s * 0.40)
      ..cubicTo(s * 0.38, s * 0.28, s * 0.62, s * 0.28, s * 0.62, s * 0.42)
      ..cubicTo(s * 0.62, s * 0.52, s * 0.50, s * 0.52, s * 0.50, s * 0.62);
    canvas.drawPath(q, p);
    canvas.drawCircle(
      Offset(s * 0.50, s * 0.74),
      stroke * 0.55,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _HelpMenuGlyphPainter old) => old.color != color;
}
