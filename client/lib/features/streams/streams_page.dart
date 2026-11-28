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
import '../../widgets/app_menu_anchor.dart';
import '../sharing/share_dialog.dart';
import '../../data/repositories.dart' show StreamDeleteTransfers;
import 'delete_stream_dialog.dart';
import 'reset_stream_dialog.dart';
import '../categories/categories_manager.dart';
import 'stream_home_layout.dart';

/// P4/P6/P9: compact 112dp stream cards on a responsive grid.
const double kStreamCardExtent = 112;
const double kStreamContentMaxWidth = 1280;
const double kStreamWideMaxWidth = 1600;

double streamContentMaxWidth(double width) =>
    width >= 1600 ? kStreamWideMaxWidth : kStreamContentMaxWidth;

/// Column counts follow viewport width when the home is in grid mode.
int streamGridColumns(Size size) {
  final w = size.width;
  if (w >= 1600) return 5;
  if (w >= 1200) return 4;
  if (w >= 900) return 3;
  if (w >= 600) return 2;
  return 1;
}

/// 16 under 600, 24 from 600 to 1199, 32 from 1200 up.
double streamPagePadding(Size size) {
  final w = size.width;
  if (w >= 1200) return 32;
  if (w >= 600) return 24;
  return 16;
}

/// P9: 8 on phone, 12 on desktop.
double streamGridGap(Size size) => size.shortestSide < 600 ? 8 : 12;

/// Opens the new-stream dialog; the stream is created inside it (errors
/// keep it open). Resolves to the created stream.
Future<BudgetStream?> createStream(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  final notifier = container.read(streamsProvider.notifier);
  final used = [
    for (final s
        in container.read(streamsProvider).valueOrNull ??
            const <BudgetStream>[])
      if (s.color != null) s.color!,
  ];
  return showStreamDialog(context, onSave: notifier.create, usedColors: used);
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
  String? _layoutPref;

  @override
  void initState() {
    super.initState();
    _layoutPref = readStreamHomeLayout();
  }

  void _setLayout(bool list) {
    final v = list ? 'list' : 'grid';
    writeStreamHomeLayout(v);
    setState(() => _layoutPref = v);
  }

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
        title: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BudgieNavbarLockup(height: 32),
              const SizedBox(width: 10),
              // Own semantics node so the label does not merge with "Budgie".
              Semantics(container: true, child: const RealtimeDot(badge: true)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(streamsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const UserMenu(showRealtimeDot: false),
          const SizedBox(width: 8),
        ],
      ),
      body: deciding && !streamsAsync.hasError
          ? const Center(child: CircularProgressIndicator())
          : PageBody(
              maxWidth: streamContentMaxWidth(MediaQuery.sizeOf(context).width),
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
            padding: EdgeInsets.fromLTRB(
              streamPagePadding(MediaQuery.sizeOf(context)),
              0,
              streamPagePadding(MediaQuery.sizeOf(context)),
              24,
            ),
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
        final size = MediaQuery.sizeOf(context);
        final cols = streamGridColumns(size);
        final gap = streamGridGap(size);
        final pad = streamPagePadding(size);
        final bg = Theme.of(context).scaffoldBackgroundColor;
        final listMode = streamHomeIsList(size.width, _layoutPref);
        final toggle = StreamLayoutToggle(
          list: listMode,
          onChanged: _setLayout,
        );

        Widget cardOf(BudgetStream stream, {required bool last}) => _StreamCard(
          stream: stream,
          listMode: listMode,
          showDivider: listMode && !last,
          canDelete: stream.role.isOwner,
          canShare: stream.role.isOwner,
          onShare: () => showShareDialog(
            context,
            ShareTarget.stream(stream.id, stream.name),
          ),
          onOpen: () => context.go('/streams/${stream.id}/timeline'),
          onEdit: () => _edit(context, stream),
          onDelete: () => _delete(context, stream),
          onReset: () => _reset(context, stream),
          onCategories: () => showCategoriesManager(
            context,
            streamId: stream.id,
            canEdit: stream.role.canEdit,
          ),
        );

        Widget listOf(List<BudgetStream> list) {
          if (listMode) {
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => cardOf(list[i], last: i == list.length - 1),
                childCount: list.length,
              ),
            );
          }
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisExtent: kStreamCardExtent,
              crossAxisSpacing: gap,
              mainAxisSpacing: gap,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => cardOf(list[i], last: i == list.length - 1),
              childCount: list.length,
            ),
          );
        }

        Widget sectionHeader({
          required String label,
          required String headerKey,
        }) => SliverPersistentHeader(
          pinned: true,
          delegate: _StickySectionDelegate(
            label: label,
            headerKey: headerKey,
            color: bg,
            padding: EdgeInsets.symmetric(horizontal: pad),
            trailing: toggle,
          ),
        );

        return CustomScrollView(
          slivers: [
            if (invites.isNotEmpty) ...[
              sectionHeader(
                label: 'Invitations for you',
                headerKey: 'invites-heading',
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, 16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    for (final i in invites) _PendingInviteTile(invite: i),
                  ]),
                ),
              ),
            ],
            if (mine.isNotEmpty) ...[
              sectionHeader(
                label: 'My streams · balance today',
                headerKey: 'mine-heading',
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  pad,
                  0,
                  pad,
                  shared.isNotEmpty ? 16 : 24,
                ),
                sliver: listOf(mine),
              ),
            ],
            if (shared.isNotEmpty) ...[
              sectionHeader(
                label: 'Shared with me · balance today',
                headerKey: 'shared-heading',
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
                sliver: listOf(shared),
              ),
            ],
          ],
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

  Future<void> _reset(BuildContext context, BudgetStream stream) =>
      confirmAndResetStream(context, ref, stream: stream);
}

class _StreamCard extends ConsumerStatefulWidget {
  const _StreamCard({
    required this.stream,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    required this.onReset,
    required this.onCategories,
    required this.onShare,
    this.canDelete = true,
    this.canShare = true,
    this.listMode = false,
    this.showDivider = false,
  });

  final VoidCallback onShare;
  final bool canDelete;
  final bool canShare;
  final bool listMode;
  final bool showDivider;
  final BudgetStream stream;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReset;
  final VoidCallback onCategories;

  @override
  ConsumerState<_StreamCard> createState() => _StreamCardState();
}

class _StreamCardState extends ConsumerState<_StreamCard> {
  final _menu = MenuController();

  BudgetStream get stream => widget.stream;

  bool get _hasMenu => true;

  void _openMenu() {
    if (!_hasMenu) return;
    if (_menu.isOpen) {
      _menu.close();
    } else {
      _menu.open();
    }
  }

  /// Whole dollars drop cents so the 12px meta line stays compact
  /// ("Seed $2,000 · 30 Sep 2026", "Alert < $0").
  String _compactMoney(num v) =>
      formatMoneyAmount(v, decimalDigits: v % 1 == 0 ? 0 : 2);

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayBalanceProvider(stream.id));
    final value = today.valueOrNull;
    final low = streamBalanceIsAlert(
      hasLoan: stream.hasLoan,
      balance: value?.toDouble(),
      threshold: stream.lossThreshold.toDouble(),
    );
    final balanceText = today.isLoading && value == null
        ? '—'
        : value == null
        ? 'No data'
        : formatHomeBalance(value.toDouble());
    final seedText = _compactMoney(stream.seedBalance.toDouble());
    final showAlert = !stream.hasLoan;
    final alertText = showAlert
        ? 'Alert < ${_compactMoney(stream.lossThreshold.toDouble())}'
        : null;
    final sharedBy = stream.shared && stream.owner != null
        ? 'Shared by ${stream.owner!.displayName}'
        : null;
    final offset = offsetIndicator(stream);
    final seedLine =
        'Seed $seedText · ${DateFormat('d MMM y').format(stream.seedDate)}';
    final semantics = [
      stream.name,
      ?sharedBy,
      ?offset,
      'Balance today $balanceText',
      if (!widget.listMode) seedLine,
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
              child: AppMenuAnchor(
                controller: _menu,
                menuChildren: [
                  if (widget.canShare)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.person_add_alt_1_outlined),
                      onPressed: widget.onShare,
                      child: const Text('Share stream…'),
                    ),
                  if (stream.role.canEdit)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.tune_rounded),
                      onPressed: widget.onEdit,
                      child: const Text('Stream settings'),
                    ),
                  MenuItemButton(
                    key: const ValueKey('stream-categories'),
                    leadingIcon: const CategoryMenuGlyph(size: 18),
                    onPressed: widget.onCategories,
                    child: const Text('Categories'),
                  ),
                  if (stream.role.canEdit || widget.canDelete)
                    const Divider(height: 8),
                  if (stream.role.canEdit)
                    resetStreamMenuItem(
                      key: const ValueKey('reset-stream'),
                      context: context,
                      enabled: true,
                      onPressed: widget.onReset,
                    ),
                  if (widget.canDelete)
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.delete_outline_rounded),
                      onPressed: widget.onDelete,
                      child: const Text('Delete stream'),
                    ),
                ],
                builder: (context, controller, _) => IconButton(
                  key: ValueKey('stream-actions-${stream.id}'),
                  tooltip: 'Stream actions',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.standard,
                    minimumSize: WidgetStatePropertyAll(Size(44, 44)),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll(EdgeInsets.zero),
                  ),
                  iconSize: 20,
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: const Icon(Icons.more_vert_rounded),
                ),
              ),
            ),
          );

    final phone = MediaQuery.sizeOf(context).shortestSide < 600;
    final pad = phone ? 12.0 : 16.0;
    final subtitle = [?sharedBy, ?offset].join(' · ');
    final tint = streamTintOf(stream);
    final chip = alertText == null
        ? null
        : StreamAlertChip(
            key: ValueKey('stream-card-alert-${stream.id}'),
            label: alertText,
            alert: low,
          );

    final nameText = Tooltip(
      message: stream.name,
      waitDuration: const Duration(milliseconds: 500),
      child: Text(
        stream.name,
        style: subtitle.isEmpty || widget.listMode
            ? kStreamNameStyle
            : kStreamNameStyle.copyWith(height: 16 / 15),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final badges = <Widget>[
      if (!stream.role.isOwner) ...[
        const SizedBox(width: 8),
        RoleChip(stream.role),
      ] else if (ownedStreamShared(ref, stream)) ...[
        const SizedBox(width: 8),
        const Tooltip(
          message: 'Shared with others',
          child: Icon(
            Icons.people_alt_outlined,
            key: ValueKey('owned-shared-badge'),
            size: 16,
            color: AppTheme.accent,
          ),
        ),
      ],
    ];

    final chevron = ExcludeSemantics(
      child: IgnorePointer(
        child: Icon(
          Icons.chevron_right_rounded,
          key: ValueKey('stream-card-chevron-${stream.id}'),
          size: 16,
          color: AppTheme.textMuted,
        ),
      ),
    );

    final Widget body;
    final double menuTop;
    if (widget.listMode) {
      final rowH = chip != null
          ? kStreamListRowWithAlert
          : kStreamListRowExtent;
      menuTop = (rowH - 44) / 2;
      body = SizedBox(
        height: rowH,
        child: Row(
          children: [
            StreamGlyphTile(
              tileKey: ValueKey('stream-card-icon-${stream.id}'),
              size: 28,
              glyphSize: 16,
              color: tint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(child: nameText),
                        ...badges,
                      ],
                    ),
                    if (chip != null) ...[const SizedBox(height: 4), chip],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ExcludeSemantics(
              child: Text(
                balanceText,
                style: streamListBalanceStyle(alert: low),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            chevron,
            if (menu != null) const SizedBox(width: 52),
          ],
        ),
      );
    } else {
      menuTop = 0;
      body = Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  StreamGlyphTile(
                    tileKey: ValueKey('stream-card-icon-${stream.id}'),
                    size: 32,
                    glyphSize: 20,
                    color: tint,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ExcludeSemantics(
                      child: subtitle.isEmpty
                          ? Row(
                              children: [
                                Expanded(child: nameText),
                                ...badges,
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: 16,
                                  child: Row(
                                    children: [
                                      Expanded(child: nameText),
                                      ...badges,
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  height: 16,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      subtitle,
                                      style: kStreamMetaStyle.copyWith(
                                        height: 1,
                                        leadingDistribution:
                                            TextLeadingDistribution.even,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  chevron,
                  if (menu != null) const SizedBox(width: 52),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      balanceText,
                      style: streamCardBalanceStyle(alert: low),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    SeedMetaRow(
                      metaKey: ValueKey('stream-card-meta-${stream.id}'),
                      seedText: 'Seed $seedText',
                      seedDate: stream.seedDate,
                      chip: chip,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final material = Material(
      color: widget.listMode ? Colors.transparent : AppTheme.surface,
      shape: widget.listMode
          ? const RoundedRectangleBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppTheme.border),
            ),
      clipBehavior: widget.listMode ? Clip.none : Clip.antiAlias,
      child: Stack(
        children: [
          RawGestureDetector(
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
                child: InkWell(onTap: widget.onOpen, child: body),
              ),
            ),
          ),
          if (menu != null) Positioned(top: menuTop, right: 0, child: menu),
        ],
      ),
    );

    if (!widget.listMode) return material;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.showDivider
            ? Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 1,
                ),
              )
            : null,
      ),
      child: material,
    );
  }
}

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
      margin: const EdgeInsets.only(bottom: 8),
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
    final pad = streamPagePadding(MediaQuery.sizeOf(context));
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 6, pad, 6),
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
                        style: kStreamMetaStyle,
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
    this.padding = EdgeInsets.zero,
    this.trailing,
  });

  final String label;
  final String headerKey;
  final Color color;
  final EdgeInsets padding;
  final Widget? trailing;

  @override
  double get minExtent => kStreamSectionHeaderExtent;

  @override
  double get maxExtent => kStreamSectionHeaderExtent;

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
        height: kStreamSectionHeaderExtent,
        alignment: Alignment.centerLeft,
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1,
                  color: AppTheme.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickySectionDelegate old) =>
      label != old.label ||
      color != old.color ||
      headerKey != old.headerKey ||
      padding != old.padding ||
      trailing != old.trailing;
}
