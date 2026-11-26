import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'page_stub.dart' if (dart.library.js_interop) 'page_web.dart' as page;

/// Reports this child's screen rect to the soft-keyboard primer so a
/// capture-phase touchend can focus the proxy without waiting for Dart
/// `onTap` (and without walking event.target, which on a real iPhone is
/// the Flutter glass pane, not a labelled semantics node).
///
/// A hotspot covered by another route (the Transactions overlay over the
/// timeline FAB, for example) is unregistered: the primer hit-tests raw
/// screen rects and cannot see Flutter z-order, so a tap on the list
/// that happens to sit over the FAB would otherwise raise the decimal
/// pad with nothing to type into.
class KbHotspot extends SingleChildRenderObjectWidget {
  const KbHotspot({
    super.key,
    required this.id,
    required this.kind,
    required Widget child,
  }) : super(child: child);

  /// Stable id (`panel-new-event`, `add-event-fab`, …).
  final String id;

  /// `decimal` (amount) or `text` (name).
  final String kind;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderKbHotspot(id: id, kind: kind);
  }

  @override
  void updateRenderObject(BuildContext context, RenderKbHotspot renderObject) {
    renderObject
      ..id = id
      ..kind = kind;
  }
}

class RenderKbHotspot extends RenderProxyBox {
  RenderKbHotspot({required String id, required String kind})
    : _id = id,
      _kind = kind;

  String _id;
  String get id => _id;
  set id(String value) {
    if (_id == value) return;
    page.unregisterKbHotspot(_id);
    _id = value;
    _publish();
  }

  String _kind;
  String get kind => _kind;
  set kind(String value) {
    if (_kind == value) return;
    _kind = value;
    _publish();
  }

  var _scheduled = false;

  void _publish() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _publishNow();
    });
  }

  void _publishNow() {
    if (!attached || !hasSize || size.isEmpty) {
      page.unregisterKbHotspot(_id);
      return;
    }
    if (_isOccluded()) {
      page.unregisterKbHotspot(_id);
      return;
    }
    final origin = localToGlobal(Offset.zero);
    page.registerKbHotspot(
      id: _id,
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      kind: _kind,
    );
  }

  /// True when a later route / overlay would win a tap at our centre.
  bool _isOccluded() {
    RenderView? view;
    for (RenderObject? n = this; n != null; n = n.parent) {
      if (n is RenderView) {
        view = n;
        break;
      }
    }
    if (view == null) return false;
    final result = BoxHitTestResult();
    view.hitTest(result, position: localToGlobal(size.center(Offset.zero)));
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderObject && _isOrUnder(t, this)) return false;
    }
    return true;
  }

  static bool _isOrUnder(RenderObject node, RenderObject ancestor) {
    for (RenderObject? n = node; n != null; n = n.parent) {
      if (identical(n, ancestor)) return true;
    }
    return false;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _publish();
  }

  @override
  void detach() {
    page.unregisterKbHotspot(_id);
    super.detach();
  }
}
