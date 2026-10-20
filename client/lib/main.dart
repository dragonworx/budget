import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app.dart';
import 'boot/app_version.dart';
import 'boot/boot_loader.dart';
import 'data/api_client.dart';
import 'state/auth_providers.dart';
import 'state/realtime_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Pushed routes (e.g. a new pool's timeline) update the browser URL,
  // so reload and browser back behave.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  _watchForUpdates();
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

/// Tabs left open across a deploy reload into the new build (see
/// [AppVersion]); while in use, offer a Reload instead.
void _watchForUpdates() {
  final version = AppVersion(current: buildId);
  if (!version.enabled) return;
  ApiClient.onOutdatedSuspected = version.suspect;
  var offered = false;
  version.onUpdateAvailable = () {
    if (offered) return;
    offered = true;
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        key: const ValueKey('update-available'),
        content: const Text('Budget was updated.'),
        duration: const Duration(days: 1),
        action: SnackBarAction(label: 'Reload', onPressed: reloadPage),
      ),
    );
  };
  version.start();
}
