import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/sharing.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sharing_ui.dart';

/// `/invite/:token`: preview an invite, then accept it. Signed-out visitors
/// are sent to sign-in by the router and come back here afterwards.
class InvitePage extends ConsumerStatefulWidget {
  const InvitePage({super.key, required this.token});
  final String token;

  @override
  ConsumerState<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends ConsumerState<InvitePage> {
  InvitePreview? _preview;
  String? _error;
  String? _errorKey;
  bool _accepting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await ref.read(sharingRepositoryProvider).preview(widget.token);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (e is ApiException && e.statusCode == 404) {
          _errorKey = 'invite-invalid';
          _error = "This invite link isn't valid. It may have been replaced by a newer link.";
        } else {
          _errorKey = 'invite-error';
          _error = friendlyError(e);
        }
      });
    }
  }

  Future<void> _accept() async {
    setState(() => _accepting = true);
    try {
      final r = await ref.read(sharingRepositoryProvider).accept(widget.token);
      ref.invalidate(accountsProvider);
      ref.invalidate(myInvitesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invite accepted: you can now ${r.role.canEdit ? 'edit' : 'view'} it')),
      );
      context.go(
        r.accountId != null ? '/accounts/${r.accountId}/timeline' : accountsPath,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _accepting = false;
        if (e is ApiException && e.statusCode == 410) {
          _errorKey = 'invite-gone';
          _error = _goneText(_statusOf(e) ?? 'expired');
        } else if (e is ApiException && e.statusCode == 403) {
          _preview = _preview == null
              ? null
              : InvitePreview(invite: _preview!.invite, emailMatches: false);
        } else {
          _errorKey = 'invite-error';
          _error = friendlyError(e);
        }
      });
    }
  }

  String? _statusOf(ApiException e) {
    final m = RegExp(r'"status"\s*:\s*"(\w+)"').firstMatch(e.body ?? '');
    return m?.group(1);
  }

  String _goneText(String status) => switch (status) {
    'accepted' => 'This invite has already been accepted.',
    'revoked' => 'This invite was cancelled by the owner.',
    _ => 'This invite has expired. Ask the owner for a new link.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = ref.watch(authProvider).valueOrNull?.user;
    final p = _preview;
    final List<Widget> body;
    if (_error != null) {
      body = [
        const Icon(Icons.link_off_rounded, size: 40, color: AppTheme.textFaint),
        const SizedBox(height: 12),
        Text(_error!, key: ValueKey<String>(_errorKey ?? 'invite-error'), textAlign: TextAlign.center),
      ];
    } else if (p == null) {
      body = [const CircularProgressIndicator()];
    } else {
      final inv = p.invite;
      final by = inv.invitedBy;
      body = [
        if (by != null) RefAvatar(by, radius: 26) else const Icon(Icons.group_add_rounded, size: 40),
        const SizedBox(height: 14),
        Text(
          '${by?.displayName ?? 'Someone'} invited you to',
          style: theme.textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          inv.targetLabel,
          key: const ValueKey('invite-target'),
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RoleChip(inv.role),
            const SizedBox(width: 8),
            Text(
              'account',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        if (inv.expiresAt != null) ...[
          const SizedBox(height: 6),
          Text(
            'Link expires ${DateFormat('d MMM y').format(inv.expiresAt!.toLocal())}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 22),
        if (!inv.pending)
          Text(_goneText(inv.status), key: const ValueKey('invite-gone'), textAlign: TextAlign.center)
        else if (!p.emailMatches) ...[
          Text(
            'This invite is for ${inv.email}, but you\'re signed in as ${me?.email ?? 'someone else'}.',
            key: const ValueKey('invite-mismatch'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('invite-switch'),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
            icon: const Icon(Icons.switch_account_rounded, size: 18),
            label: Text('Sign in as ${inv.email}'),
          ),
        ] else
          FilledButton.icon(
            key: const ValueKey('invite-accept'),
            onPressed: _accepting ? null : _accept,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(_accepting ? 'Accepting…' : 'Accept invite'),
          ),
      ];
    }
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...body,
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => context.go(accountsPath),
                      child: const Text('Go to accounts'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
