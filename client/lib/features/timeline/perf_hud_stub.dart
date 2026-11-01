// Non-web PERF_HUD hooks: nothing beyond the Dart-side stats.
void install(Map<String, Object?> Function() snapshot, void Function() reset) {}

void reset() {}

Map<String, Object?> extra() => const {};
