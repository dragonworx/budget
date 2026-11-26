import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../boot/kb_hotspot.dart';
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
          const SizedBox(width: 8),
        ],
      ),
      body: deciding && !streamsAsync.hasError
          ? const Center(child: CircularProgressIndicator())
          : PageBody(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StreamsHeader(
                    count: count,
                    onNew: count != null && count > 0
                        ? () => _create(context)
                        : null,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              for (final i in invites) _PendingInviteTile(invite: i),
              EmptyState(
                key: const ValueKey('streams-empty'),
                glyph: const StreamIcon(key: ValueKey('stream-icon')),
                title: 'No streams yet',
                message:
                    "Plan each stream's balance over time. Create a stream "
                    'with a starting (seed) balance, then add its events on '
                    'the timeline. Streams others share with you show up here '
                    'too.',
                action: KbHotspot(
                  id: 'home-new-stream-empty',
                  kind: 'text',
                  child: FilledButton.icon(
                    key: const ValueKey('new-stream'),
                    onPressed: () => _create(context),
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('New stream'),
                  ),
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
            const gap = 10.0;
            final w = (c.maxWidth - 32 - gap * (cols - 1)) / cols;
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
            final bg = Theme.of(context).scaffoldBackgroundColor;
            return CustomScrollView(
              slivers: [
                if (invites.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickySectionDelegate(
                        label: 'Invitations for you',
                        headerKey: 'invites-heading',
                        color: bg,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        for (final i in invites) _PendingInviteTile(invite: i),
                      ]),
                    ),
                  ),
                ],
                if (mine.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickySectionDelegate(
                        label: 'My streams · balance today',
                        headerKey: 'mine-heading',
                        color: bg,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverToBoxAdapter(child: grid(mine)),
                  ),
                ],
                if (shared.isNotEmpty) ...[
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _StickySectionDelegate(
                        label: 'Shared with me · balance today',
                        headerKey: 'shared-heading',
                        color: bg,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverToBoxAdapter(child: grid(shared)),
                  ),
                ] else
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
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

class _StreamCard extends ConsumerStatefulWidget {
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
  ConsumerState<_StreamCard> createState() => _StreamCardState();
}

class _StreamCardState extends ConsumerState<_StreamCard> {
  final _menuKey = GlobalKey<PopupMenuButtonState<_StreamAction>>();

  BudgetStream get stream => widget.stream;

  bool get _hasMenu => stream.role.canEdit || widget.canShare;

  void _openMenu() {
    if (!_hasMenu) return;
    _menuKey.currentState?.showButtonMenu();
  }

  /// Whole dollars drop cents so the 12px meta line stays compact
  /// ("Seed $2,000 · 30 Sep 2026", "Alert < $0").
  String _compactMoney(num v) =>
      formatMoneyAmount(v, decimalDigits: v % 1 == 0 ? 0 : 2);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = ref.watch(todayBalanceProvider(stream.id));
    final value = today.valueOrNull;
    // A loan stream runs far below zero by design: no red alert badge.
    final low =
        !stream.hasLoan &&
        value != null &&
        belowAlert(value, stream.lossThreshold);
    String money(num v) => formatMoneyAmount(v, decimalDigits: 2);
    final balanceText = today.isLoading && value == null
        ? '—'
        : value == null
        ? 'No data'
        : money(value.toDouble());
    final seedText = _compactMoney(stream.seedBalance.toDouble());
    final seedDate = DateFormat('d MMM y').format(stream.seedDate);
    final meta = 'Seed $seedText · $seedDate';
    final showAlert = !stream.hasLoan;
    final alertText = showAlert
        ? 'Alert < ${_compactMoney(stream.lossThreshold.toDouble())}'
        : null;
    final sharedBy = stream.shared && stream.owner != null
        ? 'Shared by ${stream.owner!.displayName}'
        : null;
    final offset = offsetIndicator(stream);
    final semantics = [
      stream.name,
      ?sharedBy,
      ?offset,
      'Balance today $balanceText',
      meta,
      ?alertText,
      'Open timeline',
    ].join('. ');

    final menu = !_hasMenu
        ? null
        : Semantics(
            label: 'Stream actions',
            button: true,
            child: SizedBox(
              width: 44,
              height: 44,
              child: PopupMenuButton<_StreamAction>(
                key: _menuKey,
                tooltip: 'Stream actions',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                style: const ButtonStyle(
                  visualDensity: VisualDensity.standard,
                  minimumSize: WidgetStatePropertyAll(Size(44, 44)),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                iconSize: 20,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (action) => switch (action) {
                  _StreamAction.edit => widget.onEdit(),
                  _StreamAction.delete => widget.onDelete(),
                  _StreamAction.share => widget.onShare(),
                },
                itemBuilder: (context) => [
                  if (widget.canShare)
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
                  if (widget.canDelete)
                    const PopupMenuItem(
                      value: _StreamAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline_rounded),
                        title: Text('Delete stream'),
                      ),
                    ),
                ],
              ),
            ),
          );

    return Material(
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: {
          _TouchLongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                _TouchLongPressGestureRecognizer
              >(
                () => _TouchLongPressGestureRecognizer(debugOwner: this),
                (r) => r.onLongPress = _openMenu,
              ),
        },
        child: Semantics(
          key: ValueKey('stream-card-${stream.id}'),
          container: true,
          explicitChildNodes: true,
          button: true,
          label: semantics,
          onTap: widget.onOpen,
          child: FocusableActionDetector(
            key: ValueKey('stream-card-focus-${stream.id}'),
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onOpen();
                  return null;
                },
              ),
            },
            child: InkWell(
              onTap: widget.onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ExcludeSemantics(
                            child: Row(
                              children: [
                                const IconTile.glyph(
                                  StreamIcon(key: ValueKey('stream-icon')),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Tooltip(
                                    message: stream.name,
                                    waitDuration: const Duration(
                                      milliseconds: 500,
                                    ),
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
                              ],
                            ),
                          ),
                        ),
                        ?menu,
                        ExcludeSemantics(
                          child: IgnorePointer(
                            child: Icon(
                              Icons.chevron_right_rounded,
                              key: ValueKey('stream-card-chevron-${stream.id}'),
                              size: 16,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (sharedBy != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              sharedBy,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          if (offset != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              key: const ValueKey('stream-offset-indicator'),
                              children: [
                                const Icon(
                                  Icons.savings_outlined,
                                  size: 14,
                                  color: AppTheme.textFaint,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    offset,
                                    style: theme.textTheme.bodySmall,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 34,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                balanceText,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: low
                                      ? AppTheme.debitColor
                                      : AppTheme.text,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  meta,
                                  key: ValueKey(
                                    'stream-card-meta-${stream.id}',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 16 / 12,
                                    color: AppTheme.cardMeta,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (alertText != null) ...[
                                const SizedBox(width: 8),
                                _AlertChip(
                                  key: ValueKey(
                                    'stream-card-alert-${stream.id}',
                                  ),
                                  label: alertText,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
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

/// 20dp chip: 12px bell + "Alert < $0".
class _AlertChip extends StatelessWidget {
  const _AlertChip({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.overlay,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.notifications_none_rounded,
            size: 12,
            color: AppTheme.cardMeta,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              height: 1,
              color: AppTheme.cardMeta,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Long-press opens the card's ⋮ menu, but only for a finger (or stylus)
/// so a mouse click on desktop is not delayed by the long-press arena.
class _TouchLongPressGestureRecognizer extends LongPressGestureRecognizer {
  _TouchLongPressGestureRecognizer({super.debugOwner});

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus) {
      return false;
    }
    return super.isPointerAllowed(event);
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

/// Spec 004: "Offset: Everyday" on a loan stream, "Offset for Home loan"
/// on its offset account (null: neither).
String? offsetIndicator(BudgetStream s) {
  String name(OffsetLinkRef r) =>
      r.visible && r.name != null ? r.name! : 'a stream not shared with you';
  if (s.offset case final o?) return 'Offset: ${name(o)}';
  if (s.offsetFor.isNotEmpty) {
    return 'Offset for ${s.offsetFor.map(name).join(', ')}';
  }
  return null;
}

/// P7: "Streams" and a compact + New on one row; the count is a short
/// "N streams" beside the title, not a wrapping explainer.
class _StreamsHeader extends StatelessWidget {
  const _StreamsHeader({this.count, this.onNew});

  final int? count;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phone = MediaQuery.sizeOf(context).shortestSide < 600;
    final titleStyle = theme.textTheme.headlineSmall?.copyWith(
      fontSize: phone ? 22 : 24,
      height: phone ? 28 / 22 : 32 / 24,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(
                    'Streams',
                    key: const ValueKey('streams-title'),
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (count != null && count! > 0) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _streamCountLabel(count!),
                        key: const ValueKey('streams-count'),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onNew != null) _CompactNewStreamButton(onPressed: onNew!),
          ],
        ),
      ),
    );
  }
}

String _streamCountLabel(int count) =>
    count == 1 ? '1 stream' : '$count streams';

/// 36dp tall label inside a 44dp hit area.
class _CompactNewStreamButton extends StatelessWidget {
  const _CompactNewStreamButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text('New'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        maximumSize: const Size(double.infinity, 36),
        padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    return KbHotspot(
      id: 'home-new-stream',
      kind: 'text',
      child: Tooltip(
        message: 'New stream',
        child: Semantics(
          button: true,
          label: 'New stream',
          child: SizedBox(
            key: const ValueKey('new-stream'),
            height: 44,
            child: Center(child: SizedBox(height: 36, child: button)),
          ),
        ),
      ),
    );
  }
}

class _StickySectionDelegate extends SliverPersistentHeaderDelegate {
  _StickySectionDelegate({
    required this.label,
    required this.headerKey,
    required this.color,
  });

  final String label;
  final String headerKey;
  final Color color;

  @override
  double get minExtent => 32;

  @override
  double get maxExtent => 32;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      color: color,
      child: Container(
        key: ValueKey(headerKey),
        height: 32,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 2),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1,
            color: AppTheme.textMuted,
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickySectionDelegate old) =>
      label != old.label || color != old.color || headerKey != old.headerKey;
}
