import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/projects/project_detail_page.dart';
import 'features/projects/projects_page.dart';
import 'features/timeline/timeline_page.dart';
import 'theme/app_theme.dart';

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const ProjectsPage()),
    GoRoute(
      path: '/projects/:projectId',
      builder: (context, state) {
        final projectId = state.pathParameters['projectId']!;
        return ProjectDetailPage(projectId: projectId);
      },
    ),
    GoRoute(
      path: '/accounts/:accountId/timeline',
      builder: (context, state) {
        final accountId = state.pathParameters['accountId']!;
        return TimelinePage(accountId: accountId);
      },
    ),
  ],
);

class BudgetApp extends ConsumerWidget {
  const BudgetApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Budget Tool',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      // Australian English: dd/MM/yyyy in date pickers and inputs.
      locale: const Locale('en', 'AU'),
      supportedLocales: const [Locale('en', 'AU'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}
