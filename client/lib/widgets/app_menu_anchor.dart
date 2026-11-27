import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../boot/kb_hotspot.dart';
import '../boot/page_stub.dart'
    if (dart.library.js_interop) '../boot/page_web.dart';
import '../theme/app_theme.dart';
import 'menu_placement.dart';

/// Widest a shrink-wrapped dropdown may grow. The panel is still
/// capped to the viewport when the screen is narrower.
const double kAppMenuMaxWidth = 320;

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
    this.menuChildren = const [],
    this.menuChildrenBuilder,
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
  /// Evaluated when the panel is built so items can depend on state at open time.
  final List<Widget> Function()? menuChildrenBuilder;
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
  var _escBound = false;

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
    _unbindEscape();
    if (_vvHandle != null) offVisualViewportChange(_vvHandle!);
    super.dispose();
  }

  void _bindEscape() {
    if (_escBound) return;
    HardwareKeyboard.instance.addHandler(_onEscape);
    _escBound = true;
  }

  void _unbindEscape() {
    if (!_escBound) return;
    HardwareKeyboard.instance.removeHandler(_onEscape);
    _escBound = false;
  }

  bool _onEscape(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _controller.isOpen) {
      _controller.close();
      return true;
    }
    return false;
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
      onOpen: () {
        _bindEscape();
        widget.onOpen?.call();
      },
      onClose: () {
        _unbindEscape();
        widget.onClose?.call();
      },
      builder: widget.builder,
      child: widget.child,
      overlayBuilder: (overlayContext, info) {
        // Read MediaQuery from the *anchor* context so a wrapping
        // MediaQuery (safe-area tests, or a subtree inset) is honoured.
        // The root overlay's MediaQuery is the raw view and would drop
        // those insets. [info.overlaySize] is still the overlay we paint
        // into; [menuViewport] intersects the two.
        final mq = MediaQuery.of(context);
        final viewport = menuViewport(
          overlaySize: info.overlaySize,
          viewPadding: mq.viewPadding,
          viewInsets: mq.viewInsets,
        );
        final anchor = info.anchorRect.shift(widget.alignmentOffset);
        return CustomSingleChildLayout(
          delegate: _MenuLayoutDelegate(
            anchor: anchor,
            viewport: viewport,
            prefer: widget.prefer,
            matchAnchorWidth: widget.matchAnchorWidth,
            textDirection: Directionality.of(context),
            style: widget.style,
          ),
          child: TapRegion(
            groupId: info.tapRegionGroupId,
            onTapOutside: (_) => _controller.close(),
            child: _MenuPanel(
              style: widget.style,
              children: [
                for (final child in widget.menuChildrenBuilder?.call() ??
                    widget.menuChildren)
                  forceMenuItemVerticalOverflow(child, _controller),
              ],
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
    required this.textDirection,
    this.style,
  });

  final Rect anchor;
  final Rect viewport;
  final MenuPlacement prefer;
  final bool matchAnchorWidth;
  final TextDirection textDirection;
  final MenuStyle? style;

  static const double _gap = 4;

  BoxConstraints _childConstraints() {
    final styleMin = style?.minimumSize?.resolve(const {}) ?? Size.zero;
    final styleMax = style?.maximumSize?.resolve(const {});
    var maxW = math.max(0.0, viewport.width);
    // Honour an explicit MenuStyle max width (stream/category pickers
    // go up to ~340). Otherwise cap a shrink-wrapped menu at 320 so it
    // does not stretch to the desktop viewport.
    if (styleMax != null && styleMax.width.isFinite) {
      maxW = math.min(maxW, styleMax.width);
    } else if (!matchAnchorWidth) {
      maxW = math.min(maxW, kAppMenuMaxWidth);
    }
    var minW = 0.0;
    if (matchAnchorWidth) {
      minW = math.min(anchor.width, maxW);
    } else if (styleMin.width > 0 && styleMin.width.isFinite) {
      minW = math.min(styleMin.width, maxW);
    }
    var maxH = _sideMaxHeight();
    if (styleMax != null && styleMax.height.isFinite) {
      maxH = math.min(maxH, styleMax.height);
    }
    return BoxConstraints(
      minWidth: minW,
      maxWidth: maxW,
      maxHeight: maxH,
    );
  }

  /// Cap the first layout pass to the side the menu will actually use
  /// (the roomier of above/below for a dropdown), so a long list from a
  /// low row cannot lay out taller than the remaining viewport and then
  /// spill past the edge when we only position it.
  double _sideMaxHeight() {
    if (prefer == MenuPlacement.end) {
      return math.max(0.0, viewport.height);
    }
    final below = viewport.bottom - anchor.bottom - _gap;
    final above = anchor.top - viewport.top - _gap;
    return math.max(1.0, math.max(below, above));
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      _childConstraints();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return placeMenu(
      anchor: anchor,
      wanted: childSize,
      viewport: viewport,
      prefer: prefer,
      gap: _gap,
      textDirection: textDirection,
    ).offset;
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate old) =>
      anchor != old.anchor ||
      viewport != old.viewport ||
      prefer != old.prefer ||
      matchAnchorWidth != old.matchAnchorWidth ||
      textDirection != old.textDirection ||
      style != old.style;
}

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({required this.children, this.style});

  final List<Widget> children;
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
    final padding =
        style?.padding?.resolve(const {}) ??
        const EdgeInsets.symmetric(vertical: 8);
    return Material(
      key: const ValueKey('app-menu-panel'),
      color: bg,
      elevation: elevation,
      shadowColor: Colors.black54,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// [MenuItemButton] defaults to [Axis.horizontal] overflow (the label
/// is not allowed to ellipsize) unless it is inside a Material
/// [MenuAnchor]. This menu uses [RawMenuAnchor], so we rewrite each
/// item to [Axis.vertical] and walk common wrappers.
Widget forceMenuItemVerticalOverflow(Widget widget, MenuController controller) {
  if (widget is MenuItemButton) {
    final onPressed = widget.onPressed;
    return MenuItemButton(
      key: widget.key,
      onPressed: onPressed == null
          ? null
          : () {
              // MenuItemButton.closeOnActivate uses the private
              // _MenuAnchorScope, which RawMenuAnchor does not provide.
              if (widget.closeOnActivate) controller.close();
              onPressed();
            },
      onHover: widget.onHover,
      requestFocusOnHover: widget.requestFocusOnHover,
      onFocusChange: widget.onFocusChange,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      shortcut: widget.shortcut,
      semanticsLabel: widget.semanticsLabel,
      style: widget.style,
      statesController: widget.statesController,
      clipBehavior: widget.clipBehavior,
      leadingIcon: widget.leadingIcon,
      trailingIcon: widget.trailingIcon,
      closeOnActivate: false,
      overflowAxis: Axis.vertical,
      child: widget.child,
    );
  }
  if (widget is SubmenuButton) {
    return SubmenuButton(
      key: widget.key,
      onHover: widget.onHover,
      onFocusChange: widget.onFocusChange,
      onOpen: widget.onOpen,
      onClose: widget.onClose,
      controller: widget.controller,
      style: widget.style,
      menuStyle: widget.menuStyle,
      alignmentOffset: widget.alignmentOffset,
      clipBehavior: widget.clipBehavior,
      focusNode: widget.focusNode,
      statesController: widget.statesController,
      leadingIcon: widget.leadingIcon,
      trailingIcon: widget.trailingIcon,
      submenuIcon: widget.submenuIcon,
      useRootOverlay: true,
      hoverOpenDelay: widget.hoverOpenDelay,
      animated: widget.animated,
      onAnimationStatusChanged: widget.onAnimationStatusChanged,
      menuChildren: [
        for (final child in widget.menuChildren)
          forceMenuItemVerticalOverflow(child, controller),
      ],
      child: widget.child,
    );
  }
  if (widget is Tooltip && widget.child != null) {
    return Tooltip(
      key: widget.key,
      message: widget.message,
      richMessage: widget.richMessage,
      constraints: widget.constraints,
      preferBelow: widget.preferBelow,
      waitDuration: widget.waitDuration,
      showDuration: widget.showDuration,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is KbHotspot && widget.child != null) {
    return KbHotspot(
      key: widget.key,
      id: widget.id,
      kind: widget.kind,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is Semantics && widget.child != null) {
    return Semantics(
      key: widget.key,
      container: widget.container,
      explicitChildNodes: widget.explicitChildNodes,
      excludeSemantics: widget.excludeSemantics,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is Padding && widget.child != null) {
    return Padding(
      key: widget.key,
      padding: widget.padding,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is SizedBox) {
    return SizedBox(
      key: widget.key,
      width: widget.width,
      height: widget.height,
      child: widget.child == null
          ? null
          : forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is ConstrainedBox) {
    return ConstrainedBox(
      key: widget.key,
      constraints: widget.constraints,
      child: widget.child == null
          ? null
          : forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is ExcludeFocus) {
    return ExcludeFocus(
      key: widget.key,
      excluding: widget.excluding,
      child: forceMenuItemVerticalOverflow(widget.child, controller),
    );
  }
  if (widget is Listener && widget.child != null) {
    return Listener(
      key: widget.key,
      onPointerDown: widget.onPointerDown,
      onPointerMove: widget.onPointerMove,
      onPointerUp: widget.onPointerUp,
      onPointerHover: widget.onPointerHover,
      onPointerCancel: widget.onPointerCancel,
      onPointerPanZoomStart: widget.onPointerPanZoomStart,
      onPointerPanZoomUpdate: widget.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: widget.onPointerPanZoomEnd,
      onPointerSignal: widget.onPointerSignal,
      behavior: widget.behavior,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is MouseRegion && widget.child != null) {
    return MouseRegion(
      key: widget.key,
      onEnter: widget.onEnter,
      onExit: widget.onExit,
      onHover: widget.onHover,
      cursor: widget.cursor,
      opaque: widget.opaque,
      hitTestBehavior: widget.hitTestBehavior,
      child: forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is Expanded) {
    return Expanded(
      key: widget.key,
      flex: widget.flex,
      child: forceMenuItemVerticalOverflow(widget.child, controller),
    );
  }
  if (widget is Flexible) {
    return Flexible(
      key: widget.key,
      flex: widget.flex,
      fit: widget.fit,
      child: forceMenuItemVerticalOverflow(widget.child, controller),
    );
  }
  if (widget is ColoredBox) {
    return ColoredBox(
      key: widget.key,
      color: widget.color,
      child: widget.child == null
          ? null
          : forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is DecoratedBox) {
    return DecoratedBox(
      key: widget.key,
      decoration: widget.decoration,
      position: widget.position,
      child: widget.child == null
          ? null
          : forceMenuItemVerticalOverflow(widget.child!, controller),
    );
  }
  if (widget is Flex) {
    final children = [
      for (final child in widget.children) forceMenuItemVerticalOverflow(child, controller),
    ];
    if (widget is Row) {
      return Row(
        key: widget.key,
        mainAxisAlignment: widget.mainAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        textDirection: widget.textDirection,
        verticalDirection: widget.verticalDirection,
        textBaseline: widget.textBaseline,
        spacing: widget.spacing,
        children: children,
      );
    }
    if (widget is Column) {
      return Column(
        key: widget.key,
        mainAxisAlignment: widget.mainAxisAlignment,
        mainAxisSize: widget.mainAxisSize,
        crossAxisAlignment: widget.crossAxisAlignment,
        textDirection: widget.textDirection,
        verticalDirection: widget.verticalDirection,
        textBaseline: widget.textBaseline,
        spacing: widget.spacing,
        children: children,
      );
    }
    return Flex(
      key: widget.key,
      direction: widget.direction,
      mainAxisAlignment: widget.mainAxisAlignment,
      mainAxisSize: widget.mainAxisSize,
      crossAxisAlignment: widget.crossAxisAlignment,
      textDirection: widget.textDirection,
      verticalDirection: widget.verticalDirection,
      textBaseline: widget.textBaseline,
      clipBehavior: widget.clipBehavior,
      spacing: widget.spacing,
      children: children,
    );
  }
  return widget;
}
