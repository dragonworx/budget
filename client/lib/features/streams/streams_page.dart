import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../brand/brand.dart';
import '../../data/alert.dart';
import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/sharing.dart';
import '../../state/providers.dart';
import '../../state/realtime_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/stream_dialog.dart';
import '../../widgets/stream_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/conflict_dialog.dart';
import '../../widgets/money_text.dart';
import '../../widgets/sharing_ui.dart';
import '../../widgets/ui.dart';
import '../../widgets/user_menu.dart';
import '../sharing/share_dialog.dart';
import '../../data/repositories.dart' show StreamDeleteTransfers;
import 'delete_stream_dialog.dart';

/// Opens the new-stream dialog; the stream is created inside it (errors
/// keep it open). Resolves to the created stream.
Future<BudgetStream?> createStream(BuildContext context) {
  final notifier = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(streamsProvider.notifier);
  return showStreamDialog(context, onSave: notifier.create);
}

/// Streams home: my streams, then those shared with me, and New stream.
/// Streams are top level (there are no projects). With [landing] (the `/`
/// route), the first visit after sign-in opens the last-used stream
/// instead, when I can still open it.
class StreamsPage extends ConsumerStatefulWidget {
  const StreamsPage({super.key, this.landing = false});

  final bool landing;

  @override
  ConsumerState<StreamsPage> createState() => _StreamsPageState();
}

class _StreamsPageState extends ConsumerState<StreamsPage> {
  bool _jumping = false;

  /// On the landing route, once per session: go to the last-used stream.
  void _maybeLand(List<BudgetStream> streams) {
    if (!widget.landing || _jumping || ref.read(landedProvider)) return;
    final last = ref.read(streamsProvider.notifier).lastStreamId;
    final target = streams.where((a) => a.id == last).firstOrNull;
    _jumping = target != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(landedProvider.notifier).state = true;
      if (target != null) context.go('/streams/${target.id}/timeline');
    });
  }

  @override
  Widget build(BuildContext context) {
    final streamsAsync = ref.watch(streamsProvider);
    final streams = streamsAsync.valueOrNull;
    if (streams != null && !streamsAsync.isLoading) _maybeLand(streams);
    final deciding =
        widget.landing &&
        !ref.watch(landedProvider) &&
        (streams == null || _jumping);
    final count = streams?.length;
    return Scaffold(
      appBar: AppBar(
        title: const Align(
          alignment: AlignmentDirectional.centerStart,
          child: BudgieNavbarLockup(height: 32),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(streamsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(),
          const SizedBox(width: 12),
        ],
      ),
      body: deciding && !streamsAsync.hasError
          ? const Center(child: CircularProgressIndicator())
          : PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeading(
                    title: 'Streams',
                    subtitle: count == null || count == 0
                        ? 'Plan each stream\'s balance over time'
                        : '$count stream${count == 1 ? '' : 's'} · open one to plan its balance over time',
                    actions: [
                      if (count != null && count > 0)
                        FilledButton.icon(
                          key: const ValueKey('new-stream'),
                          onPressed: () => _create(context),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('New stream'),
                        ),
                    ],
                  ),
                  Expanded(child: _body(context, streamsAsync)),
                ],
              ),
            ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<List<BudgetStream>> streamsAsync,
  ) {
    return streamsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        error: true,
        icon: Icons.cloud_off_rounded,
        title: 'Could not load streams',
        message: friendlyError(error),
        action: OutlinedButton.icon(
          onPressed: () => ref.read(streamsProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('Retry'),
        ),
      ),
      data: (streams) {
        final invites =
            ref.watch(myInvitesProvider).valueOrNull ?? const <Invite>[];
        if (streams.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              for (final i in invites) _PendingInviteTile(invite: i),
              EmptyState(
                key: const ValueKey('streams-empty'),
                glyph: const StreamIcon(key: ValueKey('stream-icon')),
                title: 'No streams yet',
                message: 'Create a stream with a starting (seed) balance, then plan its events on the timeline. Streams others share with you show up here too.',
                action: FilledButton.icon(
                  key: const ValueKey('new-stream'),
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add_rounded, size: 20),
                  label: const Text('New stream'),
                ),
              ),
            ],
          );
        }
        final mine = [
          for (final a in streams)
            if (!a.shared) a,
        ];
        final shared = [
          for (final a in streams)
            if (a.shared) a,
        ];
        return LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= 900
                ? 3
                : c.maxWidth >= 600
                ? 2
                : 1;
            const gap = 16.0;
            final w = (c.maxWidth - 48 - gap * (cols - 1)) / cols;
            Widget grid(List<BudgetStream> list) => Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final stream in list)
                  SizedBox(
                    width: w,
                    child: _StreamCard(
                      stream: stream,
                      canDelete: stream.role.isOwner,
                      canShare: stream.role.isOwner,
                      onShare: () => showShareDialog(
                        context,
                        ShareTarget.stream(stream.id, stream.name),
                      ),
                      onOpen: () =>
                          context.go('/streams/${stream.id}/timeline'),
                      onEdit: () => _edit(context, stream),
                      onDelete: () => _delete(context, stream),
                    ),
                  ),
              ],
            );
            Widget heading(String t, String key) => Padding(
              key: ValueKey(key),
              padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
              child: Text(
                t,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: AppTheme.textMuted),
              ),
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (invites.isNotEmpty) ...[
                    heading('Invitations for you', 'invites-heading'),
                    for (final i in invites) _PendingInviteTile(invite: i),
                  ],
                  if (mine.isNotEmpty && shared.isNotEmpty)
                    heading('My streams', 'mine-heading'),
                  if (mine.isNotEmpty) grid(mine),
                  if (shared.isNotEmpty) ...[
                    heading('Shared with me', 'shared-heading'),
                    grid(shared),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _create(BuildContext context) async {
    final created = await createStream(context);
    if (created != null && context.mounted) {
      context.go('/streams/${created.id}/timeline');
    }
  }

  Future<void> _edit(BuildContext context, BudgetStream existing) async {
    final notifier = ref.read(streamsProvider.notifier);
    final result = await showStreamDialog(context, existing: existing);
    if (result == null) return;
    try {
      if (!context.mounted) return;
      await saveWithConflictCheck(
        context,
        save: (force) => notifier.updateStream(result, force: force),
        reload: notifier.refresh,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }

  Future<void> _delete(BuildContext context, BudgetStream stream) async {
    // What goes with it decides the confirm: a stream with events lists
    // them and asks what happens to its transfers' far sides.
    List<BudgetEvent> events;
    try {
      events = await ref.read(eventsProvider(stream.id).future);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
      return;
    }
    if (!context.mounted) return;
    StreamDeleteTransfers? mode;
    if (events.isEmpty) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Delete stream?',
        message: '“${stream.name}” will be removed. It has no events.',
        confirmLabel: 'Delete stream',
      );
      if (confirmed) mode = StreamDeleteTransfers.keep;
    } else {
      mode = await showDeleteStreamDialog(
        context,
        stream: stream,
        events: events,
        streams: ref.read(streamsProvider).valueOrNull ?? const [],
      );
    }
    if (mode == null) return;
    try {
      await ref
          .read(streamsProvider.notifier)
          .delete(stream.id, transfers: mode);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(error))));
      }
    }
  }
}

enum _StreamAction { edit, delete, share }

class _StreamCard extends ConsumerWidget {
  const _StreamCard({
    required this.stream,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.onShare,
    this.canDelete = true,
    this.canShare = true,
  });

  final VoidCallback onShare;
  final bool canDelete;
  final bool canShare;
  final BudgetStream stream;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final today = ref.watch(todayBalanceProvider(stream.id));
    final value = today.valueOrNull;
    // A loan stream runs far below zero by design: no red alert badge.
    final low =
        !stream.hasLoan &&
        value != null &&
        belowAlert(value, stream.lossThreshold);
    String money(num v) => formatMoneyAmount(v, decimalDigits: 2);
    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('stream-card-${stream.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const IconTile.glyph(
                    StreamIcon(key: ValueKey('stream-icon')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Tooltip(
                      message: stream.name,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Text(
                        stream.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!stream.role.isOwner) ...[
                    RoleChip(stream.role),
                    const SizedBox(width: 6),
                  ] else if (ownedStreamShared(ref, stream)) ...[
                    const Tooltip(
                      message: 'Shared with others',
                      child: Icon(
                        Icons.people_alt_outlined,
                        key: ValueKey('owned-shared-badge'),
                        size: 18,
                        color: AppTheme.accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (stream.role.canEdit || canShare)
                    PopupMenuButton<_StreamAction>(
                      tooltip: 'Stream actions',
                      padding: EdgeInsets.zero,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      iconSize: 20,
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (action) => switch (action) {
                        _StreamAction.edit => onEdit(),
                        _StreamAction.delete => onDelete(),
                        _StreamAction.share => onShare(),
                      },
                      itemBuilder: (context) => [
                        if (canShare)
                          const PopupMenuItem(
                            value: _StreamAction.share,
                            child: ListTile(
                              leading: Icon(Icons.person_add_alt_1_outlined),
                              title: Text('Share stream…'),
                            ),
                          ),
                        if (stream.role.canEdit)
                          const PopupMenuItem(
                            value: _StreamAction.edit,
                            child: ListTile(
                              leading: Icon(Icons.tune_rounded),
                              title: Text('Stream settings'),
                            ),
                          ),
                        if (canDelete)
                          const PopupMenuItem(
                            value: _StreamAction.delete,
                            child: ListTile(
                              leading: Icon(Icons.delete_outline_rounded),
                              title: Text('Delete stream'),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              if (stream.shared && stream.owner != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Shared by ${stream.owner!.displayName}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'BALANCE TODAY',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textFaint,
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  height: 34,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      today.isLoading && value == null
                          ? '—'
                          : value == null
                          ? 'No data'
                          : money(value.toDouble()),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: low ? AppTheme.debitColor : AppTheme.text,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Padding(
                padding: EdgeInsets.zero,
                child: Row(
                  children: [
                    Expanded(
                      child: _Fact(
                        label:
                            'Seed · ${DateFormat('d MMM y').format(stream.seedDate)}',
                        value: money(stream.seedBalance.toDouble()),
                      ),
                    ),
                    // Loan streams don't alert (spec 003 §11).
                    if (!stream.hasLoan) ...[
                      const SizedBox(width: 12),
                      _Fact(
                        label: 'Alert at',
                        value: '< ${money(stream.lossThreshold.toDouble())}',
                        alignEnd: true,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Spacer(),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: onOpen,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                    label: const Text('Open timeline'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    this.alignEnd = false,
  });
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.text),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// An invite addressed to me that hasn't been accepted yet.
class _PendingInviteTile extends StatelessWidget {
  const _PendingInviteTile({required this.invite});
  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final by = invite.invitedBy;
    return Card(
      key: ValueKey('my-invite-${invite.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: by == null
            ? const Icon(Icons.mail_outline_rounded)
            : RefAvatar(by, radius: 16),
        title: Text(invite.targetLabel),
        subtitle: Text(
          '${by?.displayName ?? 'Someone'} invited you as ${invite.role.label.toLowerCase()}. '
          'Open the link they sent you, or sign out and back in to accept.',
        ),
        trailing: RoleChip(invite.role),
      ),
    );
  }
}
