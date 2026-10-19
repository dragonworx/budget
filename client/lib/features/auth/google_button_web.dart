import 'dart:js_interop';

import 'package:flutter/widgets.dart';

@JS('budgetGis')
external _Gis? get _gis;

extension type _Gis._(JSObject _) implements JSObject {
  external void render(
    JSObject el,
    String clientId,
    JSFunction onCredential,
    JSNumber width,
  );
  external void disableAutoSelect();
}

Widget buildGoogleButton(
  String clientId,
  ValueChanged<String> onCredential,
  double width,
) {
  return SizedBox(
    width: width,
    height: 44,
    child: HtmlElementView.fromTagName(
      key: ValueKey('gis-$clientId'),
      tagName: 'div',
      onElementCreated: (element) {
        _gis?.render(
          element as JSObject,
          clientId,
          ((JSString token) => onCredential(token.toDart)).toJS,
          width.toJS,
        );
      },
    ),
  );
}

void disableAutoSelect() => _gis?.disableAutoSelect();
