import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_prefs.dart';

/// Events hidden from the timeline on this device: a view setting only
/// (browser local storage, [PrefKeys.hiddenEvents]), never sent to the
/// server. A hidden event loses its lane, name and dot on the chart; it
/// still counts in the balance (the separate "excluded from balance"
/// flag is the event's own `enabled`). Shown again from the Events list.
/// Ids are unique across streams, so one set serves every stream.
class HiddenEventsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => readHiddenEvents();

  bool isHidden(String id) => state.contains(id);

  void hide(String id) => _set({...state, id});

  void show(String id) => _set({...state}..remove(id));

  void setHidden(String id, bool hidden) => hidden ? hide(id) : show(id);

  /// Shows every one of [ids] (e.g. a stream's events) again.
  void showAll(Iterable<String> ids) =>
      _set({...state}..removeAll(ids.toSet()));

  void _set(Set<String> next) {
    if (next.length == state.length && next.containsAll(state)) return;
    state = Set.unmodifiable(next);
    writeHiddenEvents(next);
  }
}

final hiddenEventsProvider =
    NotifierProvider<HiddenEventsNotifier, Set<String>>(
      HiddenEventsNotifier.new,
    );

/// The stored hidden ids (empty when missing or unreadable).
Set<String> readHiddenEvents() {
  final raw = appPrefs.getString(PrefKeys.hiddenEvents);
  if (raw == null || raw.isEmpty) return const {};
  try {
    final v = jsonDecode(raw);
    if (v is List) return Set.unmodifiable(v.whereType<String>());
  } on FormatException {
    // Corrupt value: treat as nothing hidden.
  }
  return const {};
}

void writeHiddenEvents(Set<String> ids) {
  if (ids.isEmpty) {
    appPrefs.remove(PrefKeys.hiddenEvents);
  } else {
    appPrefs.setString(PrefKeys.hiddenEvents, jsonEncode(ids.toList()..sort()));
  }
}
