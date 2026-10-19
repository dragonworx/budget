import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/auth_repository.dart';
import '../state/auth_providers.dart';
import '../theme/app_theme.dart';

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

/// Avatar button in the app header: email, admin badge and sign out.
/// Renders nothing when signed out.
class UserMenu extends ConsumerWidget {
  const UserMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).valueOrNull?.user;
    if (user == null) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      key: const ValueKey('user-menu'),
      tooltip: user.email,
      offset: const Offset(0, 44),
      onSelected: (v) {
        if (v == 'sign-out') ref.read(authProvider.notifier).signOut();
        if (v == 'admin') GoRouter.of(context).go('/admin');
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
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: UserAvatar(user: user),
      ),
    );
  }
}
