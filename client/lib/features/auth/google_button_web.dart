import 'dart:js_interop';

import 'package:flutter/widgets.dart';

import 'google_button.dart' show effectiveGoogleUxMode;

@JS('budgetGis')
external _Gis? get _gis;

extension type _Gis._(JSObject _) implements JSObject {
  external void render(
    JSObject el,
    String clientId,
    JSFunction onCredential,
    JSNumber width,
    String uxMode,
  );
  external void disableAutoSelect();
  external bool popupUnreliable();
  external bool inAppBrowser();
}

Widget buildGoogleButton(
  String clientId,
  ValueChanged<String> onCredential,
  double width,
  String uxMode,
) {
  final mode = effectiveGoogleUxMode(
    uxMode,
    popupUnreliable: popupUnreliable(),
  );
  return SizedBox(
    width: width,
    height: 44,
    child: HtmlElementView.fromTagName(
      key: ValueKey('gis-$clientId-$mode'),
      tagName: 'div',
      onElementCreated: (element) {
        _gis?.render(
          element as JSObject,
          clientId,
          ((JSString token) => onCredential(token.toDart)).toJS,
          width.toJS,
          mode,
        );
      },
    ),
  );
}

void disableAutoSelect() => _gis?.disableAutoSelect();

bool popupUnreliable() => _gis?.popupUnreliable() ?? false;

bool inAppBrowser() => _gis?.inAppBrowser() ?? false;
