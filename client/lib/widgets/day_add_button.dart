import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The day "+" look, shared by the timeline's day popup (pick bubble) and
/// the header's "New event today", so both read as the same action: a
/// tonal accent circle (compact) with a rounded plus.
ButtonStyle dayAddButtonStyle() => IconButton.styleFrom(
  backgroundColor: AppTheme.accent.withValues(alpha: 0.18),
  foregroundColor: AppTheme.accent,
  visualDensity: VisualDensity.compact,
);

/// The day "+" icon (see [dayAddButtonStyle]).
const dayAddIcon = Icon(Icons.add_rounded, size: 22);
