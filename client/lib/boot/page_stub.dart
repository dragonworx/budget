/// Non-web (tests): no page to reload.
void reloadPage() {}

bool get pageVisible => true;

void onPageVisible(void Function() f) {}

final _session = <String, String>{};
String? sessionGet(String key) => _session[key];
void sessionSet(String key, String value) => _session[key] = value;
