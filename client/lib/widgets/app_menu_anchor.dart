import 'package:flutter/material.dart';

import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart';
import '../theme/app_theme.dart';
import 'menu_placement.dart';

/// A popup menu that stays inside the visible screen.
///
/// Drop-in shape for [MenuAnchor]: same [builder], [menuChildren],
/// [controller], [onOpen]/[onClose]. The panel is shown in the root
/// overlay (so a parent [Scaffold] cannot clip it), placed by
/// [placeMenu] (below the anchor, flipped above or shifted to the
/// side when it would go off an edge), capped to the safe area plus
/// an 8px margin, and scrolled when the list is longer than the
/// remaining space. On web the browser visual viewport is used so
/// iOS chrome and the soft keyboard are respected; the panel is
/// repositioned on resize or rotation.
class AppMenuAnchor extends StatefulWidget {
  const AppMenuAnchor({
    super.key,
    this.controller,
    required this.menuChildren,
    this.builder,
    this.child,
    this.onOpen,
    this.onClose,
    this.style,
    this.alignmentOffset = Offset.zero,
    this.matchAnchorWidth = false,
    this.prefer = MenuPlacement.below,
    this.consumeOutsideTaps = false,
  });

  final MenuController? controller;
  final List<Widget> menuChildren;
  final RawMenuAnchorChildBuilder? builder;
  final Widget? child;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final MenuStyle? style;
  final Offset alignmentOffset;
  final bool matchAnchorWidth;
  final MenuPlacement prefer;
  final bool consumeOutsideTaps;

  @override
  State<AppMenuAnchor> createState() => _AppMenuAnchorState();
}

class _AppMenuAnchorState extends State<AppMenuAnchor>
    with WidgetsBindingObserver {
  late final MenuController _owned = MenuController();
  Object? _vvHandle;

  MenuController get _controller => widget.controller ?? _owned;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vvHandle = onVisualViewportChange(_relayout);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_vvHandle != null) offVisualViewportChange(_vvHandle!);
    super.dispose();
  }

  void _relayout() {
    if (mounted && _controller.isOpen) setState(() {});
  }

  @override
  void didChangeMetrics() => _relayout();

  @override
  Widget build(BuildContext context) {
    return RawMenuAnchor(
      controller: _controller,
      useRootOverlay: true,
      consumeOutsideTaps: widget.consumeOutsideTaps,
      onOpen: widget.onOpen,
      onClose: widget.onClose,
      builder: widget.builder,
      child: widget.child,
      overlayBuilder: (context, info) {
        final mq = MediaQuery.of(context);
        final viewport = menuViewport(
          overlaySize: info.overlaySize,
          viewPadding: mq.viewPadding,
          viewInsets: mq.viewInsets,
        );
        final anchor = Rect.fromLTRB(
          info.anchorRect.left + widget.alignmentOffset.dx,
          info.anchorRect.top,
          info.anchorRect.right + widget.alignmentOffset.dx,
          info.anchorRect.bottom + widget.alignmentOffset.dy,
        );
        return CustomSingleChildLayout(
          delegate: _MenuLayoutDelegate(
            anchor: anchor,
            viewport: viewport,
            prefer: widget.prefer,
            matchAnchorWidth: widget.matchAnchorWidth,
          ),
          child: TapRegion(
            groupId: info.tapRegionGroupId,
            onTapOutside: (_) => _controller.close(),
            child: _MenuPanel(
              style: widget.style,
              minWidth: widget.matchAnchorWidth
                  ? info.anchorRect.width
                  : 0,
              children: widget.menuChildren,
            ),
          ),
        );
      },
    );
  }
}

class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  _MenuLayoutDelegate({
    required this.anchor,
    required this.viewport,
    required this.prefer,
    required this.matchAnchorWidth,
  });

  final Rect anchor;
  final Rect viewport;
  final MenuPlacement prefer;
  final bool matchAnchorWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final minW = matchAnchorWidth
        ? viewport.width.clamp(0.0, anchor.width)
        : 0.0;
    return BoxConstraints(
      minWidth: minW,
      maxWidth: viewport.width,
      maxHeight: viewport.height,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return placeMenu(
      anchor: anchor,
      wanted: childSize,
      viewport: viewport,
      prefer: prefer,
    ).offset;
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate old) =>
      anchor != old.anchor ||
      viewport != old.viewport ||
      prefer != old.prefer ||
      matchAnchorWidth != old.matchAnchorWidth;
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({
    required this.children,
    required this.minWidth,
    this.style,
  });

  final List<Widget> children;
  final double minWidth;
  final MenuStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final popup = theme.popupMenuTheme;
    final bg =
        style?.backgroundColor?.resolve(const {}) ??
        popup.color ??
        AppTheme.raised;
    final shape =
        style?.shape?.resolve(const {}) ??
        popup.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.border),
        );
    final elevation = popup.elevation ?? 8;
    return Material(
      key: const ValueKey('app-menu-panel'),
      color: bg,
      elevation: elevation,
      shadowColor: Colors.black54,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth),
        child: SingleChildScrollView(
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
