import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'page_stub.dart' if (dart.library.js_interop) 'page_web.dart' as page;

/// Reports this child's screen rect to the soft-keyboard primer so a
/// capture-phase touchend can focus the proxy without waiting for Dart
/// `onTap` (and without walking event.target, which on a real iPhone is
/// the Flutter glass pane, not a labelled semantics node).
///
/// On `?kb=d`, a transparent DOM `<input>` is placed over the rect so
/// the finger lands on a real field; [onActivate] then opens the sheet
/// (the overlay swallows the tap, so Flutter's `onPressed` will not run).
class KbHotspot extends SingleChildRenderObjectWidget {
  const KbHotspot({
    super.key,
    required this.id,
    required this.kind,
    this.onActivate,
    required Widget child,
  }) : super(child: child);

  /// Stable id (`panel-new-event`, `add-event-fab`, …).
  final String id;

  /// `decimal` (amount) or `text` (name).
  final String kind;

  /// Used by the `?kb=d` overlay when it intercepts the tap.
  final VoidCallback? onActivate;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderKbHotspot(id: id, kind: kind, onActivate: onActivate);
  }

  @override
  void updateRenderObject(BuildContext context, RenderKbHotspot renderObject) {
    renderObject
      ..id = id
      ..kind = kind
      ..onActivate = onActivate;
  }
}

class RenderKbHotspot extends RenderProxyBox {
  RenderKbHotspot({
    required String id,
    required String kind,
    VoidCallback? onActivate,
  }) : _id = id,
       _kind = kind,
       _onActivate = onActivate;

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

  VoidCallback? _onActivate;
  VoidCallback? get onActivate => _onActivate;
  set onActivate(VoidCallback? value) {
    if (identical(_onActivate, value)) return;
    _onActivate = value;
    _publish();
  }

  void _publish() {
    if (!hasSize || !attached) return;
    final origin = localToGlobal(Offset.zero);
    page.registerKbHotspot(
      id: _id,
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      kind: _kind,
      onActivate: _onActivate,
    );
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
