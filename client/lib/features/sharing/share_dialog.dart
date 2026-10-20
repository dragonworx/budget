import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/sharing.dart';
import '../../state/auth_providers.dart';
import '../../state/providers.dart';
import '../../state/realtime_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/sharing_ui.dart';

/// Opens the share dialog for a pool. Resolves true when the user left
/// it (callers navigate away).
Future<bool> showShareDialog(BuildContext context, ShareTarget target) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => ShareDialog(target: target),
  );
  return r ?? false;
}

class ShareDialog extends ConsumerStatefulWidget {
  const ShareDialog({super.key, required this.target});
  final ShareTarget target;

  @override
  ConsumerState<ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<ShareDialog> {
  ShareInfo? _info;
  Object? _loadError;
  final _email = TextEditingController();
  Role _inviteRole = Role.viewer;
  bool _busy = false;
  String? _inviteError;

  /// Link of the invite just created / rotated, shown with a copy button.
  String? _link;
  String? _linkFor;

  SharingRepository get _repo => ref.read(sharingRepositoryProvider);
  ShareTarget get _t => widget.target;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await _repo.load(_t);
      if (mounted) setState(() => (_info = info, _loadError = null));
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      // Roles and lists elsewhere depend on sharing.
      ref.invalidate(poolsProvider);
      if (done != null) _toast(done);
    } catch (e) {
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _inviteError = 'Enter an email address');
      return;
    }
    setState(() {
      _busy = true;
      _inviteError = null;
    });
    try {
      final r = await _repo.invite(_t, email, _inviteRole);
      _email.clear();
      if (r.added) {
        _toast('$email now has access');
      } else {
        setState(() => (_link = r.link, _linkFor = email));
      }
      await _load();
    } catch (e) {
      setState(() => _inviteError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    _toast('Invite link copied');
  }

  Future<void> _rotate(Invite inv) => _run(() async {
    final link = await _repo.rotateLink(inv.id);
    setState(() => (_link = link, _linkFor = inv.email));
    await Clipboard.setData(ClipboardData(text: link));
  }, done: 'New link copied (the old one no longer works)');

  Future<void> _leave() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Leave “${_t.name}”?',
      message: "You'll lose access until someone invites you again.",
      confirmLabel: 'Leave',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await _repo.leave(_t);
      ref.invalidate(poolsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _toast(friendlyError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Member m, ShareTarget on) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Remove ${m.user.displayName}?',
      message: 'They lose access to “${on.name}”.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    await _run(() => _repo.remove(on, m.userId), done: 'Removed ${m.user.email}');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sharingEpochProvider, (_, _) => _load());
    final theme = Theme.of(context);
    final info = _info;
    final isOwner = info?.role == Role.owner;
    final me = ref.watch(authProvider).valueOrNull?.user;
    final width = MediaQuery.sizeOf(context).width;
    return AlertDialog(
      key: const ValueKey('share-dialog'),
      insetPadding: EdgeInsets.symmetric(horizontal: width < 500 ? 12 : 40, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      title: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Share “${_t.name}”', maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  'Pool',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(false),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: info == null
            ? SizedBox(
                height: 120,
                child: Center(
                  child: _loadError == null
                      ? const CircularProgressIndicator()
                      : Text(friendlyError(_loadError!)),
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isOwner) ..._inviteSection(theme),
                    if (_link != null) _linkBox(theme),
                    _heading(theme, 'People with access'),
                    for (final m in info.members) _memberRow(m, info, me?.id, isOwner),
                    for (final m in info.poolShares) _memberRow(m, info, me?.id, isOwner),
                    if (isOwner && info.invites.any((i) => i.pending)) ...[
                      _heading(theme, 'Pending invites'),
                      for (final i in info.invites.where((i) => i.pending)) _inviteRow(i, theme),
                    ],
                    if (!isOwner) ...[
                      const SizedBox(height: 12),
                      Text(
                        info.role == Role.editor
                            ? 'You can edit. Only the owner can share.'
                            : 'You can view only. Only the owner can share.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (info != null && !isOwner && _canLeave(info, me?.id))
          TextButton.icon(
            key: const ValueKey('share-leave'),
            onPressed: _busy ? null : _leave,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Leave pool'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Done'),
        ),
      ],
    );
  }

  /// Only a share holder can leave (the owner deletes instead).
  bool _canLeave(ShareInfo info, String? myId) =>
      info.poolShares.any((m) => m.userId == myId);

  Widget _heading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 4),
    child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: AppTheme.textMuted)),
  );

  List<Widget> _inviteSection(ThemeData theme) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('share-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Invite by email',
              hintText: 'name@example.com',
              errorText: _inviteError,
              isDense: true,
            ),
            onSubmitted: (_) => _invite(),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<Role>(
          key: const ValueKey('share-invite-role'),
          value: _inviteRole,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: Role.viewer, child: Text('Viewer')),
            DropdownMenuItem(value: Role.editor, child: Text('Editor')),
          ],
          onChanged: (r) => setState(() => _inviteRole = r ?? Role.viewer),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        key: const ValueKey('share-invite'),
        onPressed: _busy ? null : _invite,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
        label: const Text('Invite'),
      ),
    ),
  ];

  Widget _linkBox(ThemeData theme) => Container(
    key: const ValueKey('share-link-box'),
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
    decoration: BoxDecoration(
      color: AppTheme.accentSoft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Send this link to ${_linkFor ?? 'them'}',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.text),
              ),
              const SizedBox(height: 2),
              SelectableText(
                _link!,
                key: const ValueKey('share-link'),
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.accent),
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('share-copy-link'),
          tooltip: 'Copy link',
          onPressed: () => _copy(_link!),
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
    ),
  );

  Widget _memberRow(Member m, ShareInfo info, String? myId, bool isOwner) {
    final theme = Theme.of(context);
    final isMe = m.userId == myId;
    final on = _t;
    final editable = isOwner && m.role != Role.owner && !isMe;
    return Padding(
      key: ValueKey('member-${m.user.email}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          RefAvatar(m.user, radius: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${m.user.displayName}${isMe ? ' (you)' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    if (m.user.name != null && m.user.name!.isNotEmpty) m.user.email,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (editable)
            DropdownButton<Role>(
              key: ValueKey('member-role-${m.user.email}'),
              value: m.role == Role.editor ? Role.editor : Role.viewer,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: Role.viewer, child: Text('Viewer')),
                DropdownMenuItem(value: Role.editor, child: Text('Editor')),
              ],
              onChanged: _busy
                  ? null
                  : (r) {
                      if (r == null || r == m.role) return;
                      _run(() => _repo.setRole(on, m.userId, r),
                          done: '${m.user.displayName} is now ${r.label.toLowerCase()}');
                    },
            )
          else
            RoleChip(m.role),
          if (editable)
            PopupMenuButton<String>(
              key: ValueKey('member-menu-${m.user.email}'),
              tooltip: 'More for ${m.user.displayName}',
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (_) => _remove(m, on),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'remove',
                  child: ListTile(
                    leading: Icon(Icons.person_remove_outlined),
                    title: Text('Remove access'),
                  ),
                ),
              ],
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _inviteRow(Invite i, ThemeData theme) {
    final exp = i.expiresAt;
    return Padding(
      key: ValueKey('invite-${i.email}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 16,
            backgroundColor: AppTheme.overlay,
            child: Icon(Icons.mail_outline_rounded, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(i.email, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [
                    '${i.role.label} · pending',
                    if (exp != null) 'expires ${DateFormat('d MMM').format(exp.toLocal())}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('invite-link-${i.email}'),
            tooltip: 'Copy a new link',
            onPressed: _busy ? null : () => _rotate(i),
            icon: const Icon(Icons.link_rounded, size: 20),
          ),
          IconButton(
            key: ValueKey('invite-revoke-${i.email}'),
            tooltip: 'Revoke invite',
            onPressed: _busy
                ? null
                : () => _run(() => _repo.revoke(i.id), done: 'Invite to ${i.email} revoked'),
            icon: const Icon(Icons.block_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
