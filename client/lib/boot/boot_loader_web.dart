import 'dart:js_interop';

@JS('budgetLoader')
external _Loader? get _loader;

extension type _Loader._(JSObject _) implements JSObject {
  external void stage(String name, [String? label]);
  external void progress(String name, JSNumber? fraction, [String? label]);
  external void done([String? name]);
  external void error(String message);
}

void stage(String name, String? label) => _loader?.stage(name, label);
void progress(String name, double? fraction, String? label) =>
    _loader?.progress(name, fraction?.toJS, label);
void done(String? name) => name == null ? _loader?.done() : _loader?.done(name);
void error(String message) => _loader?.error(message);
