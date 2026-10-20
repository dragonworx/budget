import 'dart:convert';

import 'package:budget_client/app.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/auth_repository.dart';
import 'package:budget_client/features/auth/google_button.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_pools.dart';
import 'support/fake_auth.dart';

Future<(ProviderContainer, FakeAuthRepository, FakePoolRepository)> _pump(
  WidgetTester tester,
  FakeAuthRepository auth, {
  FakePoolRepository? pools,
}) async {
  final repo = pools ?? FakePoolRepository();
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      poolRepositoryProvider.overrideWithValue(repo),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  return (container, auth, repo);
}

String _path(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

void main() {
  group('authRedirect', () {
    Uri u(String s) => Uri.parse(s);
    test('waits while unresolved', () {
      expect(
        authRedirect(resolved: false, signedIn: false, location: u('/')),
        isNull,
      );
    });
    test('signed out goes to sign-in keeping the target', () {
      expect(
        authRedirect(resolved: true, signedIn: false, location: u('/')),
        '/sign-in',
      );
      expect(
        authRedirect(
          resolved: true,
          signedIn: false,
          location: u('/pools'),
        ),
        '/sign-in?from=%2Fpools',
      );
    });
    test('signed in leaves sign-in for the target', () {
      expect(
        authRedirect(
          resolved: true,
          signedIn: true,
          location: u('/sign-in?from=%2Fpools'),
        ),
        '/pools',
      );
      expect(
        authRedirect(
          resolved: true,
          signedIn: true,
          location: u('/sign-in?from=//evil.com'),
        ),
        '/',
      );
      expect(
        authRedirect(resolved: true, signedIn: true, location: u('/')),
        isNull,
      );
    });
  });

  testWidgets('signed out shows sign-in; no data fetched', (tester) async {
    final (c, _, repo) = await _pump(tester, FakeAuthRepository());
    expect(_path(c), '/sign-in');
    expect(find.text('Sign in to see your pools'), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-login')), findsNothing);
    expect(find.byKey(const ValueKey('google-not-configured')), findsOneWidget);
    expect(repo.lists, 0);
  });

  testWidgets('dev bypass button signs in as admin', (tester) async {
    final (c, auth, repo) = await _pump(
      tester,
      FakeAuthRepository(devBypass: true),
    );
    expect(find.text('Continue as admin (dev mode)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dev-login')));
    await tester.pumpAndSettle();
    expect(auth.devLogins, 1);
    expect(_path(c), '/');
    // First sign-in, no pools: the Pools home with New pool.
    expect(find.text('Pools'), findsWidgets);
    expect(find.byKey(const ValueKey('pools-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-pool')), findsOneWidget);
    expect(find.text('New project'), findsNothing);
    expect(repo.lists, greaterThan(0));
  });

  testWidgets('user menu shows email, admin badge and signs out', (
    tester,
  ) async {
    final (c, auth, _) = await _pump(
      tester,
      FakeAuthRepository(user: adminUser),
    );
    expect(_path(c), '/');
    await tester.tap(find.byKey(const ValueKey('user-menu')));
    await tester.pumpAndSettle();
    expect(find.text('musicartscience@gmail.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('admin-badge')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sign-out')));
    await tester.pumpAndSettle();
    expect(auth.logouts, 1);
    expect(_path(c), '/sign-in');
  });

  testWidgets('a 401 from the API sends you to sign-in', (tester) async {
    final (c, _, _) = await _pump(tester, FakeAuthRepository(user: adminUser));
    c.read(routerProvider).go('/pools');
    ApiClient.onUnauthorized?.call();
    await tester.pumpAndSettle();
    expect(_path(c), '/sign-in?from=%2Fpools');
    // Signing back in returns to where you were.
    await c.read(authProvider.notifier).devLogin();
    await tester.pump();
    expect(_path(c), '/pools');
  });

  testWidgets('a failed full-page sign-in shows its error, not a blank page', (
    tester,
  ) async {
    final (c, _, _) = await _pump(
      tester,
      FakeAuthRepository(googleClientId: 'cid.apps.googleusercontent.com'),
    );
    // What /api/auth/google/redirect sends back on failure.
    c
        .read(routerProvider)
        .go(
          '/sign-in?${Uri(queryParameters: {'error': 'wife@gmail.com is not on the allowlist.'}).query}',
        );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sign-in-error')), findsOneWidget);
    expect(
      find.text('wife@gmail.com is not on the allowlist.'),
      findsOneWidget,
    );
    expect(find.text('Sign in to see your pools'), findsOneWidget);
  });

  testWidgets('stuck popup: full-page sign-in fallback is offered', (
    tester,
  ) async {
    await _pump(
      tester,
      FakeAuthRepository(googleClientId: 'cid.apps.googleusercontent.com'),
    );
    final use = find.byKey(const ValueKey('use-redirect-sign-in'));
    expect(use, findsOneWidget);
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(use, findsNothing);
    expect(find.byKey(const ValueKey('google-sign-in-r')), findsOneWidget);
  });

  test('auto UX uses a redirect only where popups cannot report back', () {
    expect(effectiveGoogleUxMode('auto', popupUnreliable: false), 'popup');
    expect(effectiveGoogleUxMode('auto', popupUnreliable: true), 'redirect');
    expect(effectiveGoogleUxMode('popup', popupUnreliable: true), 'popup');
    expect(
      effectiveGoogleUxMode('redirect', popupUnreliable: false),
      'redirect',
    );
    expect(
      AuthConfig.fromJson({'googleUxMode': 'redirect'}).googleUxMode,
      'redirect',
    );
    expect(AuthConfig.fromJson({}).googleUxMode, 'auto');
  });

  testWidgets('config failure shows retry on sign-in', (tester) async {
    final auth = FakeAuthRepository(failConfig: true);
    await _pump(tester, auth);
    expect(find.byKey(const ValueKey('sign-in-config-error')), findsOneWidget);
    auth.failConfig = false;
    auth.devBypass = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dev-login')), findsOneWidget);
  });

  group('ApiClient', () {
    test('sends the custom headers and reports 401', () async {
      late http.Request seen;
      var unauthorized = 0;
      ApiClient.onUnauthorized = () => unauthorized++;
      addTearDown(() => ApiClient.onUnauthorized = null);
      final api = ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((r) async {
          seen = r;
          return http.Response(jsonEncode({'error': 'nope'}), 401);
        }),
      );
      await expectLater(api.get('/api/pools'), throwsA(isA<ApiException>()));
      expect(seen.headers['X-Requested-With'], 'budget');
      expect(seen.headers['X-Client-Id'], ApiClient.clientId);
      expect(unauthorized, 1);
      // Auth endpoints don't trigger the redirect hook.
      await expectLater(api.get('/api/auth/me'), throwsA(isA<ApiException>()));
      expect(unauthorized, 1);
    });

    test('HttpAuthRepository parses config and users', () async {
      final api = ApiClient(
        baseUrl: 'http://x',
        httpClient: MockClient((r) async {
          if (r.url.path == '/api/auth/config') {
            return http.Response(
              jsonEncode({
                'googleClientId': 'abc.apps.googleusercontent.com',
                'devBypass': true,
                'user': {
                  'id': 'u1',
                  'email': 'a@b.com',
                  'picture_url': 'http://p',
                  'is_admin': true,
                },
              }),
              200,
            );
          }
          expect(r.url.path, '/api/auth/google');
          expect(jsonDecode(r.body), {'credential': 'tok'});
          return http.Response(jsonEncode({'id': 'u2', 'email': 'c@d'}), 200);
        }),
      );
      final repo = HttpAuthRepository(api);
      final cfg = await repo.config();
      expect(cfg.googleClientId, 'abc.apps.googleusercontent.com');
      expect(cfg.devBypass, isTrue);
      expect(cfg.user!.isAdmin, isTrue);
      expect(cfg.user!.pictureUrl, 'http://p');
      final u = await repo.signInWithGoogle('tok');
      expect(u.email, 'c@d');
    });
  });
}
