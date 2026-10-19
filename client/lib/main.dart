import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app.dart';
import 'boot/boot_loader.dart';
import 'state/auth_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Pushed routes (e.g. a new account's timeline) update the browser URL,
  // so reload and browser back behave.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  final container = ProviderContainer();
  runApp(
    UncontrolledProviderScope(container: container, child: const BudgetApp()),
  );
  BootLoader.finishWhenReady(
    authReady: container
        .read(authProvider.future)
        .then((s) => s.signedIn, onError: (_) => false),
  );
}
