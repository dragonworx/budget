import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';

/// Round avatar for a [UserRef] (picture, else initials).
class RefAvatar extends StatelessWidget {
  const RefAvatar(this.user, {super.key, this.radius = 14});
  final UserRef user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final pic = user.pictureUrl;
    final has = pic != null && pic.isNotEmpty;
    return Tooltip(
      message: user.email,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: AppTheme.overlay,
        foregroundImage: has ? NetworkImage(pic) : null,
        onForegroundImageError: has ? (_, _) {} : null,
        child: Text(
          user.initials,
          style: TextStyle(
            fontSize: radius * 0.75,
            fontWeight: FontWeight.w600,
            color: AppTheme.text,
          ),
        ),
      ),
    );
  }
}

/// Small "Viewer" / "Editor" / "Owner" chip.
class RoleChip extends StatelessWidget {
  const RoleChip(this.role, {super.key});
  final Role role;

  @override
  Widget build(BuildContext context) {
    final color = switch (role) {
      Role.owner => AppTheme.accent,
      Role.editor => AppTheme.violet,
      Role.viewer => AppTheme.textFaint,
    };
    return Container(
      key: ValueKey('role-chip-${role.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        role.label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
