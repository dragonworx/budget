import 'package:budget_client/app.dart';
import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/data/sharing.dart';
import 'package:budget_client/features/sharing/share_dialog.dart';
import 'package:budget_client/features/transactions/transactions_panel.dart';
import 'package:budget_client/state/auth_providers.dart';
import 'package:budget_client/state/providers.dart';
import 'package:budget_client/widgets/conflict_dialog.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_auth.dart';

const _owner = UserRef(id: 'u1', email: 'musicartscience@gmail.com', name: 'Ali');
const _bob = UserRef(id: 'u2', email: 'bob@example.com', name: 'Bob');

Account _acct(String id, {Role role = Role.owner}) => Account(
  id: id,
  projectId: 'p1',
  name: 'Everyday',
  currency: 'AUD',
  seedBalance: Decimal.zero,
  seedDate: DateTime(2026, 10, 1),
  lossThreshold: Decimal.zero,
  role: role,
);

class FakeSharing implements SharingRepository {
  final calls = <String>[];
  ShareInfo info = const ShareInfo(
    role: Role.owner,
    members: [
      Member(user: _owner, role: Role.owner),
      Member(user: _bob, role: Role.viewer),
    ],
    invites: [Invite(id: 'i1', email: 'carol@example.com', role: Role.editor)],
  );
  InvitePreview? preview_;
  Object? acceptError;
  Object? previewError;
  List<AdminUser> users_ = const [
    AdminUser(user: _owner, isAdmin: true),
    AdminUser(user: _bob),
  ];
  Allowlist allow = const Allowlist(entries: ['@example.com']);

  @override
  Future<ShareInfo> load(ShareTarget t) async => info;
  @override
  Future<InviteResult> invite(ShareTarget t, String email, Role role) async {
    calls.add('invite $email ${role.name}');
    return const InviteResult(added: false, token: 'tok123');
  }

  @override
  Future<void> setRole(ShareTarget t, String userId, Role role) async =>
      calls.add('role $userId ${role.name}');
  @override
  Future<void> remove(ShareTarget t, String userId) async => calls.add('remove $userId');
  @override
  Future<void> leave(ShareTarget t) async => calls.add('leave ${t.id}');
  @override
  Future<void> transferOwnership(String p, String u) async => calls.add('transfer $u');
  @override
  Future<String> rotateLink(String id) async {
    calls.add('rotate $id');
    return inviteLink('new');
  }

  @override
  Future<void> revoke(String id) async => calls.add('revoke $id');
  @override
  Future<List<Invite>> myInvites() async => const [];
  @override
  Future<InvitePreview> preview(String token) async {
    if (previewError != null) throw previewError!;
    return preview_!;
  }

  @override
  Future<AcceptedInvite> accept(String token) async {
    calls.add('accept $token');
    if (acceptError != null) throw acceptError!;
    return const AcceptedInvite(projectId: 'p9', role: Role.viewer);
  }

  @override
  Future<List<AdminUser>> users() async => users_;
  @override
  Future<void> setDisabled(String id, bool d) async => calls.add('disable $id $d');
  @override
  Future<Allowlist> allowlist() async => allow;
  @override
  Future<void> addAllowed(String p) async => calls.add('allow $p');
  @override
  Future<void> removeAllowed(String p) async => calls.add('disallow $p');
}

class _Projects extends ProjectRepository {
  _Projects(this.items) : super(ApiClient());
  final List<Project> items;
  @override
  Future<List<Project>> list() async => items;
  @override
  Future<Project> get(String id) async =>
      items.firstWhere((p) => p.id == id, orElse: () => Project(id: id, name: 'X'));
}

class _Accounts extends AccountRepository {
  _Accounts() : super(ApiClient());
  @override
  Future<List<Account>> listForProject(String projectId) async => const [];
}

Future<ProviderContainer> _app(
  WidgetTester tester, {
  required FakeSharing sharing,
  List<Project> projects = const [],
  String path = '/',
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [
      authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: adminUser)),
      projectRepositoryProvider.overrideWithValue(_Projects(projects)),
      accountRepositoryProvider.overrideWithValue(_Accounts()),
      sharingRepositoryProvider.overrideWithValue(sharing),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: c, child: const BudgetApp()),
  );
  await tester.pumpAndSettle();
  if (path != '/') {
    c.read(routerProvider).go(path);
    await tester.pumpAndSettle();
  }
  return c;
}

String _path(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

Future<void> _dialog(WidgetTester tester, FakeSharing sharing, {ShareTarget? target}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(FakeAuthRepository(user: adminUser)),
        sharingRepositoryProvider.overrideWithValue(sharing),
        projectRepositoryProvider.overrideWithValue(_Projects(const [])),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showShareDialog(
                context,
                target ?? const ShareTarget.project('p1', 'Home'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('models', () {
    test('project sharing fields parse', () {
      final p = Project.fromJson({
        'id': 'p',
        'name': 'Shared',
        'version': 3,
        'role': 'viewer',
        'access': 'account',
        'shared': true,
        'owner': {'id': 'u1', 'email': 'a@b.co', 'name': null},
        'sharedAccountIds': ['a1'],
      });
      expect(p.role, Role.viewer);
      expect(p.limited, isTrue);
      expect(p.shared, isTrue);
      expect(p.owner!.email, 'a@b.co');
      expect(p.sharedAccountIds, ['a1']);
      expect(p.version, 3);
    });

    test('older payloads default to owner', () {
      expect(Project.fromJson({'id': 'p', 'name': 'n'}).role, Role.owner);
    });

    test('unreadable transfer peer reads "Private account"', () {
      final l = TransferLink.fromJson({
        'peerAccountId': 'x',
        'peerReadable': false,
        'peerAccountName': null,
      });
      expect(l.accountLabel, 'Private account');
    });

    test('transaction update sends version unless forced', () {
      final t = Transaction.fromJson({
        'id': 't',
        'accountId': 'a',
        'name': 'Rent',
        'direction': 'debit',
        'amount': '10',
        'startDate': '2026-10-01',
        'recurrenceMode': 'once',
        'version': 7,
      });
      expect(t.version, 7);
      expect(t.copyWith(name: 'x').version, 7);
    });
  });

  group('share dialog', () {
    testWidgets('owner sees members, changes a role, invites and copies a link',
        (tester) async {
      final s = FakeSharing();
      await _dialog(tester, s);
      expect(find.byKey(const ValueKey('share-dialog')), findsOneWidget);
      expect(find.text('Ali (you)'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-carol@example.com')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('member-role-bob@example.com')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Editor').last);
      await tester.pumpAndSettle();
      expect(s.calls, contains('role u2 editor'));

      await tester.enterText(find.byKey(const ValueKey('share-email')), 'dan@example.com');
      await tester.tap(find.byKey(const ValueKey('share-invite')));
      await tester.pumpAndSettle();
      expect(s.calls, contains('invite dan@example.com viewer'));
      expect(find.byKey(const ValueKey('share-link-box')), findsOneWidget);
      expect(find.textContaining('/invite/tok123'), findsOneWidget);
    });

    testWidgets('revoke and rotate pending invites; transfer ownership', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      final s = FakeSharing();
      await _dialog(tester, s);
      await tester.tap(find.byKey(const ValueKey('invite-link-carol@example.com')));
      await tester.pumpAndSettle();
      expect(find.textContaining('/invite/new'), findsOneWidget);
      expect(s.calls, contains('rotate i1'));
      await tester.tap(find.byKey(const ValueKey('invite-revoke-carol@example.com')));
      await tester.pumpAndSettle();
      expect(s.calls, contains('revoke i1'));

      await tester.tap(find.byKey(const ValueKey('member-menu-bob@example.com')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer ownership'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();
      expect(s.calls, contains('transfer u2'));
    });

    testWidgets('a viewer sees no invite controls and can leave', (tester) async {
      final s = FakeSharing()
        ..info = const ShareInfo(
          role: Role.viewer,
          members: [
            Member(user: _owner, role: Role.owner),
            Member(user: UserRef(id: 'u1x', email: 'x@y.co'), role: Role.viewer),
            Member(user: UserRef(id: 'u1', email: 'me@y.co'), role: Role.viewer),
          ],
        );
      await _dialog(tester, s);
      expect(find.byKey(const ValueKey('share-email')), findsNothing);
      expect(find.byKey(const ValueKey('member-role-x@y.co')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('share-leave')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(s.calls, contains('leave p1'));
      expect(find.byKey(const ValueKey('share-dialog')), findsNothing);
    });
  });

  test('invite links (real path) start the router on the invite', () {
    expect(initialLocationFor(Uri.parse('https://x.dev/invite/abc')), '/invite/abc');
    expect(initialLocationFor(Uri.parse('https://x.dev/invite/abc#/')), '/invite/abc');
    expect(initialLocationFor(Uri.parse('https://x.dev/#/projects/p')), '/');
    expect(initialLocationFor(Uri.parse('https://x.dev/')), '/');
  });

  group('invite page', () {
    Invite inv({String status = 'pending'}) => Invite(
      id: 'i1',
      email: 'musicartscience@gmail.com',
      role: Role.viewer,
      projectId: 'p9',
      projectName: 'Holiday',
      invitedBy: _bob,
      status: status,
    );

    testWidgets('preview then accept opens the project', (tester) async {
      final s = FakeSharing()..preview_ = InvitePreview(invite: inv(), emailMatches: true);
      final c = await _app(tester, sharing: s, path: '/invite/tok');
      expect(find.byKey(const ValueKey('invite-target')), findsOneWidget);
      expect(find.text('Holiday'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('invite-accept')));
      await tester.pumpAndSettle();
      expect(s.calls, contains('accept tok'));
      expect(_path(c), '/projects/p9');
    });

    testWidgets('signed in as someone else', (tester) async {
      final s = FakeSharing()..preview_ = InvitePreview(invite: inv(), emailMatches: false);
      await _app(tester, sharing: s, path: '/invite/tok');
      expect(find.byKey(const ValueKey('invite-mismatch')), findsOneWidget);
      expect(find.byKey(const ValueKey('invite-accept')), findsNothing);
    });

    testWidgets('expired on accept (410)', (tester) async {
      final s = FakeSharing()
        ..preview_ = InvitePreview(invite: inv(), emailMatches: true)
        ..acceptError = ApiException('gone', statusCode: 410, body: '{"details":{"status":"expired"}}');
      await _app(tester, sharing: s, path: '/invite/tok');
      await tester.tap(find.byKey(const ValueKey('invite-accept')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('invite-gone')), findsOneWidget);
      expect(find.textContaining('expired'), findsOneWidget);
    });

    testWidgets('unknown token (404)', (tester) async {
      final s = FakeSharing()..previewError = ApiException('not found', statusCode: 404);
      await _app(tester, sharing: s, path: '/invite/zzz');
      expect(find.byKey(const ValueKey('invite-invalid')), findsOneWidget);
    });

    testWidgets('signed out: sign-in first, then back to the invite', (tester) async {
      final auth = FakeAuthRepository(devBypass: true);
      final s = FakeSharing()..preview_ = InvitePreview(invite: inv(), emailMatches: true);
      final c = ProviderContainer(overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        projectRepositoryProvider.overrideWithValue(_Projects(const [])),
        sharingRepositoryProvider.overrideWithValue(s),
      ]);
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const BudgetApp()));
      await tester.pumpAndSettle();
      c.read(routerProvider).go('/invite/tok');
      await tester.pumpAndSettle();
      expect(_path(c), '/sign-in?from=%2Finvite%2Ftok');
      expect(find.text('Sign in to accept your invite'), findsOneWidget);
      await c.read(authProvider.notifier).devLogin();
      await tester.pumpAndSettle();
      expect(_path(c), '/invite/tok');
      expect(find.byKey(const ValueKey('invite-accept')), findsOneWidget);
    });
  });

  testWidgets('projects page splits mine and shared, with owner and role', (tester) async {
    await _app(
      tester,
      sharing: FakeSharing(),
      projects: const [
        Project(id: 'p1', name: 'Mine'),
        Project(id: 'p2', name: 'Theirs', shared: true, role: Role.viewer, owner: _bob),
        Project(
          id: 'p3',
          name: 'Bits',
          shared: true,
          limited: true,
          role: Role.editor,
          owner: _bob,
          sharedAccountIds: ['a1'],
        ),
      ],
    );
    expect(find.byKey(const ValueKey('shared-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('owner-avatar')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('role-chip-viewer')), findsOneWidget);
    expect(find.text('1 shared account only · Owner Bob'), findsOneWidget);
    // My own project has another member -> shared badge.
    expect(find.byKey(const ValueKey('owned-shared-badge')), findsOneWidget);
  });

  testWidgets('viewer gets a read-only transactions panel', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transactionRepositoryProvider.overrideWithValue(_NoTx()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TransactionsPanel(
              account: _acct('a1', role: Role.viewer),
              skipsFor: (_) => const {},
              onPanelClosed: (_) {},
              onLocate: (_) {},
              onChanged: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('panel-view-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-new-transaction')), findsNothing);
    expect(find.text('New transaction'), findsNothing);
  });

  group('version conflict', () {
    Future<SaveResult?> run(WidgetTester tester, String button, List<bool> saves,
        List<String> log) async {
      SaveResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await saveWithConflictCheck(
                context,
                save: (force) async {
                  saves.add(force);
                  if (!force) {
                    throw ApiException('version conflict', statusCode: 409);
                  }
                },
                reload: () => log.add('reload'),
              );
            },
            child: const Text('save'),
          ),
        ),
      ));
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      expect(find.text('Changed by someone else'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(button)));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('overwrite saves again without the version', (tester) async {
      final saves = <bool>[];
      final r = await run(tester, 'conflict-overwrite', saves, []);
      expect(saves, [false, true]);
      expect(r, SaveResult.saved);
    });

    testWidgets('reload discards the edit', (tester) async {
      final saves = <bool>[];
      final log = <String>[];
      final r = await run(tester, 'conflict-reload', saves, log);
      expect(saves, [false]);
      expect(log, ['reload']);
      expect(r, SaveResult.reloaded);
    });
  });

  testWidgets('admin page: users disable and allowlist add/remove', (tester) async {
    final s = FakeSharing();
    await _app(tester, sharing: s, path: '/admin');
    expect(find.byKey(const ValueKey('admin-user-bob@example.com')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('admin-user-enabled-bob@example.com')));
    await tester.pumpAndSettle();
    expect(s.calls, contains('disable u2 true'));
    await tester.tap(find.byKey(const ValueKey('admin-tab-allowlist')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('allowlist-input')), 'zed@x.com');
    await tester.tap(find.byKey(const ValueKey('allowlist-add')));
    await tester.pumpAndSettle();
    expect(s.calls, contains('allow zed@x.com'));
    await tester.tap(find.byKey(const ValueKey('allow-remove-@example.com')));
    await tester.pumpAndSettle();
    expect(s.calls, contains('disallow @example.com'));
  });
}

class _NoTx extends TransactionRepository {
  _NoTx() : super(ApiClient());
  @override
  Future<List<Transaction>> listForAccount(String accountId) async => const [];
}
