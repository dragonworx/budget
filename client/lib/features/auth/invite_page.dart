import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Placeholder for `/invite/:token`; accepting invites arrives with sharing.
class InvitePage extends StatelessWidget {
  const InvitePage({super.key, required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Invitation')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mail_outline_rounded, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Invitations will be accepted here soon.',
                key: ValueKey('invite-stub'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Go to projects'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
