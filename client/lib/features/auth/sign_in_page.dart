import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../state/auth_providers.dart';
import '../../theme/app_theme.dart';
import 'google_button.dart';

class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  bool _busy = false;
  String? _error;

  /// Set by "Use full-page sign-in": skip the popup entirely.
  bool _forceRedirect = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final notifier = ref.read(authProvider.notifier);
    final theme = Theme.of(context);
    final config = auth.valueOrNull;
    final clientId = config?.googleClientId;
    // A failed full-page (redirect) sign-in comes back as ?error=...
    final returnedError = GoRouterState.of(context)
        .uri
        .queryParameters['error'];
    final shownError = _error ?? returnedError;

    final children = <Widget>[
      const Icon(Icons.timeline_rounded, color: AppTheme.accent, size: 44),
      const SizedBox(height: 12),
      Text('Budget', style: theme.textTheme.headlineMedium),
      const SizedBox(height: 6),
      Text(
        (GoRouterState.of(context).uri.queryParameters['from'] ?? '')
                .startsWith('/invite/')
            ? 'Sign in to accept your invite'
            : 'Sign in to see your projects',
        style: theme.textTheme.bodyMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 28),
    ];

    if (auth.hasError && config == null) {
      children.addAll([
        Text(
          "Can't reach the sign-in service. ${friendlyError(auth.error!)}",
          key: const ValueKey('sign-in-config-error'),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => ref.invalidate(authProvider),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Retry'),
        ),
      ]);
    } else if (config == null) {
      children.add(const CircularProgressIndicator());
    } else {
      if (clientId != null) {
        if (inAppBrowser()) {
          children.addAll([
            Text(
              'This page is open inside another app. If Google sign-in '
              'gets stuck on a blank page, open this link in Safari or '
              'Chrome instead.',
              key: const ValueKey('in-app-browser-warning'),
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 16),
          ]);
        }
        children.add(
          GoogleSignInButton(
            key: ValueKey('google-sign-in-${_forceRedirect ? 'r' : 'a'}'),
            clientId: clientId,
            uxMode: _forceRedirect ? 'redirect' : config.googleUxMode,
            onCredential: (token) =>
                _run(() => notifier.signInWithGoogle(token)),
          ),
        );
        if (!_forceRedirect && config.googleUxMode != 'redirect') {
          children.addAll([
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('use-redirect-sign-in'),
              onPressed: () => setState(() => _forceRedirect = true),
              child: const Text(
                'Google window stuck or blank? Use full-page sign-in',
                textAlign: TextAlign.center,
              ),
            ),
          ]);
        }
      } else {
        children.add(
          Text(
            'Google sign-in is not configured yet.',
            key: const ValueKey('google-not-configured'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        );
      }
      if (config.devBypass) {
        children.addAll([
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const ValueKey('dev-login'),
            onPressed: _busy ? null : () => _run(notifier.devLogin),
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: const Text('Continue as admin (dev mode)'),
          ),
        ]);
      }
    }
    if (_busy) {
      children.addAll([
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
      ]);
    }
    if (shownError != null && shownError.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 16),
        Text(
          shownError,
          key: const ValueKey('sign-in-error'),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ]);
    }

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
