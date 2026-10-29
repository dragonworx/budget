import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Narrowest the docked list can be dragged.
const double dockedListMinDrag = 280;

/// Room the timeline (with its paddings) always keeps beside the list.
const double dockedTimelineMin = 560;

/// Default docked list width for a [screenWidth]-wide window.
double dockedListWidth(double screenWidth) =>
    (screenWidth * 0.3).clamp(384.0, 420.0).toDouble();

/// Widest the docked list may be in a [screenWidth]-wide window: the
/// timeline keeps [dockedTimelineMin] and at least 40% of the window.
double dockedListMaxWidth(
  double screenWidth, {
  double minWidth = dockedListMinDrag,
  double timelineMin = dockedTimelineMin,
}) {
  final a = screenWidth - timelineMin, b = screenWidth * 0.6;
  return (a < b ? a : b).clamp(minWidth, double.infinity).toDouble();
}

/// The docked list width to use: the one this device chose by dragging
/// ([saved], px) clamped to the window, else the default.
double dockedListEffectiveWidth(
  double screenWidth,
  double? saved, {
  double minWidth = dockedListMinDrag,
  double timelineMin = dockedTimelineMin,
}) => (saved ?? dockedListWidth(screenWidth))
    .clamp(
      minWidth,
      dockedListMaxWidth(
        screenWidth,
        minWidth: minWidth,
        timelineMin: timelineMin,
      ),
    )
    .toDouble();

/// The splitter's hit area reaches this far past the 16px gap on each side
/// (onto the cards' borders): ~24px to grab with a finger.
const double _overlap = 4;

/// [timeline] with the docked [panel] on its right (revealed by [reveal],
/// 0 hidden … 1 shown) and a draggable splitter in the gap between them.
///
/// The drag lives here, so only this row relayouts while dragging: the
/// [timeline] and [panel] widgets are reused, their contents don't rebuild,
/// and the chart only gets a new width (its date window stays).
class DockSplit extends StatefulWidget {
  const DockSplit({
    super.key,
    required this.timeline,
    required this.panel,
    required this.reveal,
    required this.open,
    required this.savedWidth,
    required this.onWidthChanged,
    required this.onReset,
    this.minWidth = dockedListMinDrag,
    this.timelineMin = dockedTimelineMin,
    this.label = 'Resize the events list',
  });

  final Widget timeline;
  final Widget panel;
  final Animation<double> reveal;

  /// Open (not easing closed): only then can the splitter be dragged.
  final bool open;

  /// This device's chosen width (px), or null for the default.
  final double? savedWidth;

  /// A drag ended at this width (px, already clamped).
  final ValueChanged<double> onWidthChanged;

  /// Double-click / double-tap: back to the default width.
  final VoidCallback onReset;

  /// Narrowest the [panel] can be dragged (the planner needs more room
  /// than the list).
  final double minWidth;

  /// Room the [timeline] always keeps (the planner also docks on phones in
  /// landscape, where the list's 560px would leave it no travel).
  final double timelineMin;

  /// What the splitter resizes, for screen readers.
  final String label;

  @override
  State<DockSplit> createState() => _DockSplitState();
}

class _DockSplitState extends State<DockSplit> {
  double? _drag;
  double _from = 0, _startWidth = 0;
  bool _hover = false;

  void _end() {
    final w = _drag;
    if (w == null) return;
    setState(() => _drag = null);
    widget.onWidthChanged(w);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final width =
        _drag ??
        dockedListEffectiveWidth(
          screen,
          widget.savedWidth,
          minWidth: widget.minWidth,
          timelineMin: widget.timelineMin,
        );
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: widget.timeline),
        SizeTransition(
          key: const ValueKey('docked-events'),
          sizeFactor: widget.reveal,
          axis: Axis.horizontal,
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 16, 10),
            child: SizedBox(width: width, child: widget.panel),
          ),
        ),
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        row,
        AnimatedBuilder(
          animation: widget.reveal,
          builder: (context, _) {
            final f = widget.reveal.value;
            if (f <= 0) return const SizedBox.shrink();
            final ready = widget.open && f >= 1;
            return Positioned(
              top: 0,
              bottom: 0,
              // In the gap left of the panel, sliding with it.
              right: (width + 16) * f - _overlap,
              width: 16 + 2 * _overlap,
              child: _splitter(screen, width, ready),
            );
          },
        ),
      ],
    );
  }

  Widget _splitter(double screen, double width, bool ready) {
    final active = ready && (_hover || _drag != null);
    return MouseRegion(
      key: const ValueKey('dock-splitter'),
      cursor: ready ? SystemMouseCursors.resizeColumn : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        label: widget.label,
        hint: 'Drag; double-tap to reset',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: ready
              ? (d) => setState(() {
                  _from = d.globalPosition.dx;
                  _startWidth = width;
                  _drag = width;
                })
              : null,
          onHorizontalDragUpdate: ready
              ? (d) {
                  final next = (_startWidth - (d.globalPosition.dx - _from))
                      .clamp(
                        widget.minWidth,
                        dockedListMaxWidth(
                          screen,
                          minWidth: widget.minWidth,
                          timelineMin: widget.timelineMin,
                        ),
                      )
                      .toDouble();
                  if (next != _drag) setState(() => _drag = next);
                }
              : null,
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          onDoubleTap: ready ? widget.onReset : null,
          // A short grip at rest; hovered / dragging, a full-height accent
          // line marks the edge.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Container(
                key: const ValueKey('dock-splitter-line'),
                width: active ? 3 : 4,
                height: active ? double.infinity : 40,
                decoration: BoxDecoration(
                  color: active
                      ? AppTheme.accent.withValues(alpha: 0.85)
                      : AppTheme.textMuted.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
