import 'api_client.dart';
import 'models.dart';

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

/// An account's owner or share holder.
class Member {
  const Member({
    required this.user,
    required this.role,
    this.addedAt,
    this.accountId,
    this.accountName,
  });

  final UserRef user;
  final Role role;
  final DateTime? addedAt;

  /// Set for account shares.
  final String? accountId;
  final String? accountName;

  String get userId => user.id;

  factory Member.fromJson(Map<String, dynamic> j) => Member(
    user: UserRef.maybe({...j, 'id': j['userId'] ?? j['id']})!,
    role: Role.parse(j['role'], Role.viewer),
    addedAt: _dt(j['addedAt']),
    accountId: j['accountId']?.toString(),
    accountName: j['accountName']?.toString(),
  );
}

class Invite {
  const Invite({
    required this.id,
    required this.email,
    required this.role,
    this.accountId,
    this.accountName,
    this.invitedBy,
    this.status = 'pending',
    this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String email;
  final Role role;
  final String? accountId;
  final String? accountName;
  final UserRef? invitedBy;
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  bool get pending => status == 'pending';

  /// The shared account's name.
  String get targetLabel => accountName ?? 'an account';

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
    id: j['id'].toString(),
    email: (j['email'] ?? '').toString(),
    role: Role.parse(j['role'], Role.viewer),
    accountId: j['accountId']?.toString(),
    accountName: j['accountName']?.toString(),
    invitedBy: UserRef.maybe(j['invitedBy']),
    status: (j['status'] ?? 'pending').toString(),
    createdAt: _dt(j['createdAt']),
    expiresAt: _dt(j['expiresAt']),
  );
}

/// An account's owner, its shares (all of them for the owner, else just
/// mine) and, for the owner, pending invites.
class ShareInfo {
  const ShareInfo({
    required this.role,
    this.members = const [],
    this.accountShares = const [],
    this.invites = const [],
  });

  /// My role on the account.
  final Role role;

  /// The owner (one entry).
  final List<Member> members;
  final List<Member> accountShares;
  final List<Invite> invites;

  static List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) => [
    for (final e in (v as List?) ?? const [])
      f(Map<String, dynamic>.from(e as Map)),
  ];

  factory ShareInfo.fromJson(Map<String, dynamic> j) => ShareInfo(
    role: Role.parse(j['role'], Role.viewer),
    members: j['owner'] is Map
        ? [
            Member.fromJson({
              ...Map<String, dynamic>.from(j['owner'] as Map),
              'role': 'owner',
            }),
          ]
        : _list(j['members'], Member.fromJson),
    accountShares: _list(j['accountShares'] ?? j['shares'], Member.fromJson),
    invites: _list(j['invites'], Invite.fromJson),
  );
}

/// Result of inviting by email: added directly, or a pending invite + link.
class InviteResult {
  const InviteResult({required this.added, this.invite, this.token, this.inviteUrl});
  final bool added;
  final Invite? invite;
  final String? token;
  final String? inviteUrl;

  /// Link to share, on this site's origin.
  String? get link => token != null ? inviteLink(token!) : inviteUrl;
}

class InvitePreview {
  const InvitePreview({required this.invite, required this.emailMatches});
  final Invite invite;
  final bool emailMatches;
}

class AcceptedInvite {
  const AcceptedInvite({this.accountId, required this.role});
  final String? accountId;
  final Role role;
}

class AdminUser {
  const AdminUser({
    required this.user,
    this.isAdmin = false,
    this.disabled = false,
    this.createdAt,
    this.lastLoginAt,
    this.ownedAccounts = 0,
  });
  final UserRef user;
  final bool isAdmin;
  final bool disabled;
  final DateTime? createdAt;
  final DateTime? lastLoginAt;
  final int ownedAccounts;

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
    user: UserRef.maybe(j)!,
    isAdmin: j['isAdmin'] == true,
    disabled: j['disabled'] == true,
    createdAt: _dt(j['createdAt']),
    lastLoginAt: _dt(j['lastLoginAt']),
    ownedAccounts: (j['ownedAccounts'] as num?)?.toInt() ?? 0,
  );
}

class Allowlist {
  const Allowlist({
    this.env = const [],
    this.admins = const [],
    this.openSignup = false,
    this.invitesBypassAllowlist = false,
    this.entries = const [],
  });
  final List<String> env;
  final List<String> admins;
  final bool openSignup;
  final bool invitesBypassAllowlist;
  final List<String> entries;

  static List<String> _s(dynamic v) => [
    for (final e in (v as List?) ?? const [])
      e is Map ? e['pattern'].toString() : e.toString(),
  ];

  factory Allowlist.fromJson(Map<String, dynamic> j) => Allowlist(
    env: _s(j['env']),
    admins: _s(j['admins']),
    openSignup: j['openSignup'] == true,
    invitesBypassAllowlist: j['invitesBypassAllowlist'] == true,
    entries: _s(j['entries']),
  );
}

/// The account being shared.
class ShareTarget {
  const ShareTarget.account(this.id, this.name);
  final String id;
  final String name;
  String get _base => '/api/accounts/$id';
}

/// Sharing, invites and admin endpoints (plan §4b).
class SharingRepository {
  SharingRepository(this._api);
  final ApiClient _api;

  Map<String, dynamic> _map(dynamic d) =>
      d is Map ? Map<String, dynamic>.from(d) : const {};

  Future<ShareInfo> load(ShareTarget t) async => ShareInfo.fromJson(
    _map(await _api.get('${t._base}/shares')),
  );

  Future<InviteResult> invite(ShareTarget t, String email, Role role) async {
    final d = _map(
      await _api.post(
        '${t._base}/invites',
        body: {'email': email, 'role': role.name},
      ),
    );
    final inv = d['invite'];
    return InviteResult(
      added: d['status'] == 'added',
      invite: inv is Map ? Invite.fromJson(Map<String, dynamic>.from(inv)) : null,
      token: d['token']?.toString(),
      inviteUrl: d['inviteUrl']?.toString(),
    );
  }

  Future<void> setRole(ShareTarget t, String userId, Role role) =>
      _api.patch('${t._base}/shares/$userId', body: {'role': role.name});

  Future<void> remove(ShareTarget t, String userId) =>
      _api.delete('${t._base}/shares/$userId');

  Future<void> leave(ShareTarget t) => _api.post('${t._base}/leave');

  /// New link for a pending invite; the old one stops working.
  Future<String> rotateLink(String inviteId) async {
    final d = _map(await _api.post('/api/invites/$inviteId/link'));
    final token = d['token']?.toString();
    return token != null ? inviteLink(token) : (d['inviteUrl'] ?? '').toString();
  }

  Future<void> revoke(String inviteId) => _api.delete('/api/invites/$inviteId');

  Future<List<Invite>> myInvites() async {
    final d = _map(await _api.get('/api/invites'));
    return [
      for (final e in (d['invites'] as List?) ?? const [])
        Invite.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
  }

  Future<InvitePreview> preview(String token) async {
    final d = _map(await _api.post('/api/invites/preview', body: {'token': token}));
    return InvitePreview(
      invite: Invite.fromJson(Map<String, dynamic>.from(d['invite'] as Map)),
      emailMatches: d['emailMatches'] == true,
    );
  }

  Future<AcceptedInvite> accept(String token) async {
    final d = _map(await _api.post('/api/invites/accept', body: {'token': token}));
    return AcceptedInvite(
      accountId: d['accountId']?.toString(),
      role: Role.parse(d['role'], Role.viewer),
    );
  }

  // Admin
  Future<List<AdminUser>> users() async {
    final d = _map(await _api.get('/api/admin/users'));
    return [
      for (final e in (d['users'] as List?) ?? const [])
        AdminUser.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
  }

  Future<void> setDisabled(String userId, bool disabled) =>
      _api.patch('/api/admin/users/$userId', body: {'disabled': disabled});

  Future<Allowlist> allowlist() async =>
      Allowlist.fromJson(_map(await _api.get('/api/admin/allowlist')));

  Future<void> addAllowed(String pattern) =>
      _api.post('/api/admin/allowlist', body: {'pattern': pattern});

  Future<void> removeAllowed(String pattern) => _api.delete(
    '/api/admin/allowlist/${Uri.encodeComponent(pattern)}',
  );
}

/// `<this site>/invite/<token>`.
String inviteLink(String token) {
  final base = Uri.base;
  final origin = (base.scheme == 'http' || base.scheme == 'https')
      ? base.origin
      : 'http://localhost';
  return '$origin/invite/$token';
}
