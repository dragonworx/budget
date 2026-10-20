import 'dart:async';

import 'package:budget_client/features/timeline/timeline_page.dart';

/// Widget tests use the overlay Transactions list (the timeline at full
/// width) unless they opt in to docking (see docked_list_test.dart).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  dockedListEnabled = false;
  await testMain();
}
