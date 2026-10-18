import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app.dart';
import 'boot/boot_loader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Pushed routes (e.g. a new account's timeline) update the browser URL,
  // so reload and browser back behave.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  runApp(const ProviderScope(child: BudgetApp()));
  BootLoader.finishWhenReady();
}
