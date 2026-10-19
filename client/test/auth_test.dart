import 'dart:convert';

import 'package:budget_client/app.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/auth_repository.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_auth.dart';

class _Projects implements ProjectRepository {
  int lists = 0;
  @override
  Future<List<Project>> list() async {
    lists++;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<(ProviderContainer, FakeAuthRepository, _Projects)> _pump(
  WidgetTester tester,
  FakeAuthRepository auth,
) async {
  final projects = _Projects();
  final container = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      projectRepositoryProvider.overrideWithValue(projects),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  return (container, auth, projects);
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
          location: u('/projects/p1'),
        ),
        '/sign-in?from=%2Fprojects%2Fp1',
      );
    });
    test('signed in leaves sign-in for the target', () {
      expect(
        authRedirect(
          resolved: true,
          signedIn: true,
          location: u('/sign-in?from=%2Fprojects%2Fp1'),
        ),
        '/projects/p1',
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
    final (c, _, projects) = await _pump(tester, FakeAuthRepository());
    expect(_path(c), '/sign-in');
    expect(find.text('Sign in to see your projects'), findsOneWidget);
    expect(find.byKey(const ValueKey('dev-login')), findsNothing);
    expect(find.byKey(const ValueKey('google-not-configured')), findsOneWidget);
    expect(projects.lists, 0);
  });

  testWidgets('dev bypass button signs in as admin', (tester) async {
    final (c, auth, projects) = await _pump(
      tester,
      FakeAuthRepository(devBypass: true),
    );
    expect(find.text('Continue as admin (dev mode)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dev-login')));
    await tester.pumpAndSettle();
    expect(auth.devLogins, 1);
    expect(_path(c), '/');
    expect(find.text('Projects'), findsWidgets);
    expect(projects.lists, greaterThan(0));
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
    c.read(routerProvider).go('/projects/p1');
    ApiClient.onUnauthorized?.call();
    await tester.pumpAndSettle();
    expect(_path(c), '/sign-in?from=%2Fprojects%2Fp1');
    // Signing back in returns to where you were.
    await c.read(authProvider.notifier).devLogin();
    await tester.pump();
    expect(_path(c), '/projects/p1');
  });

  testWidgets('invite route stub renders when signed in', (tester) async {
    final (c, _, _) = await _pump(tester, FakeAuthRepository(user: adminUser));
    c.read(routerProvider).go('/invite/abc');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('invite-stub')), findsOneWidget);
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
      await expectLater(api.get('/api/projects'), throwsA(isA<ApiException>()));
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
