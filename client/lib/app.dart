import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/admin/admin_page.dart';
import 'features/auth/invite_page.dart';
import 'features/auth/sign_in_page.dart';
import 'features/pools/pools_page.dart';
import 'features/timeline/timeline_page.dart';
import 'state/auth_providers.dart';
import 'state/realtime_providers.dart';
import 'theme/app_theme.dart';

const signInPath = '/sign-in';

/// The pools home (list, New pool). `/` is the same page, but the
/// first visit after sign-in jumps straight to the last-used pool.
const poolsPath = '/pools';

/// Where the guard sends [location] for the given auth state, or null to stay.
/// Pure so it can be unit-tested.
String? authRedirect({
  required bool resolved,
  required bool signedIn,
  required Uri location,
}) {
  if (!resolved) return null;
  final path = location.path;
  final onSignIn = path == signInPath;
  if (!signedIn) {
    if (onSignIn) return null;
    final from = location.toString();
    return from == '/'
        ? signInPath
        : Uri(path: signInPath, queryParameters: {'from': from}).toString();
  }
  if (onSignIn) {
    final from = location.queryParameters['from'];
    return (from != null && from.startsWith('/') && !from.startsWith('//'))
        ? from
        : '/';
  }
  return null;
}

/// Invite links are `<origin>/invite/<token>` (a real path), while the app
/// routes on the URL hash: start there when no hash route is set.
String initialLocationFor(Uri base) {
  final noHashRoute = base.fragment.isEmpty || base.fragment == '/';
  if (noHashRoute && RegExp(r'^/invite/[^/]+$').hasMatch(base.path)) {
    return base.path;
  }
  return '/';
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);
  final router = GoRouter(
    initialLocation: initialLocationFor(Uri.base),
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      return authRedirect(
        // Config failure: show sign-in (with its retry) rather than the app.
        resolved: auth.hasValue || auth.hasError,
        signedIn: auth.valueOrNull?.signedIn ?? false,
        location: state.uri,
      );
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const PoolsPage(landing: true),
      ),
      GoRoute(
        path: poolsPath,
        builder: (context, state) => const PoolsPage(),
      ),
      GoRoute(
        path: signInPath,
        builder: (context, state) => const SignInPage(),
      ),
      GoRoute(path: '/admin', builder: (context, state) => const AdminPage()),
      GoRoute(
        path: '/invite/:token',
        builder: (context, state) =>
            InvitePage(token: state.pathParameters['token']!),
      ),
      // Old project links (projects are gone): the pools home.
      GoRoute(path: '/projects/:projectId', redirect: (_, _) => poolsPath),
      // Old account links (accounts are now pools).
      GoRoute(path: '/accounts', redirect: (_, _) => poolsPath),
      GoRoute(
        path: '/accounts/:id/timeline',
        redirect: (_, state) => '/pools/${state.pathParameters['id']}/timeline',
      ),
      GoRoute(
        path: '/accounts/:id',
        redirect: (_, state) => '/pools/${state.pathParameters['id']}/timeline',
      ),
      GoRoute(
        path: '/pools/:poolId/timeline',
        builder: (context, state) {
          final poolId = state.pathParameters['poolId']!;
          return TimelinePage(poolId: poolId);
        },
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

class BudgetApp extends ConsumerWidget {
  const BudgetApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    ref.watch(realtimeControllerProvider);
    return MaterialApp.router(
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'Budget Tool',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      // Until we know who is signed in, don't build pages (they would fetch).
      builder: (context, child) {
        final auth = ref.watch(authProvider);
        if (auth.isLoading && !auth.hasValue && !auth.hasError) {
          return const ColoredBox(color: AppTheme.bg);
        }
        return child ?? const SizedBox.shrink();
      },
      // Australian English: dd/MM/yyyy in date pickers and inputs.
      locale: const Locale('en', 'AU'),
      supportedLocales: const [Locale('en', 'AU'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
    );
  }
}
