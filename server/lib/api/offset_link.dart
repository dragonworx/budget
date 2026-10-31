import 'package:budget_loan/budget_loan.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/authz.dart' show Authz, Role, uuidRe;
import '../auth/authz_middleware.dart' show accessOf;
import '../auth/middleware.dart' show authOf;
import '../domain/models.dart';

/// A rejected offset link (spec 004 rule 2): [status] 400, 403 or 409.
class OffsetLinkError implements Exception {
  const OffsetLinkError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

const offsetFlatMessage = 'offset is not available for a flat-rate loan';
const offsetOwnerOnly = 'only the stream owner can change the offset account';
const offsetMaxOne = 'a loan can have at most 1 offset account';
const offsetSelf = 'a loan cannot be its own offset account';
const offsetOtherOwner =
    "the offset account must be one of the loan owner's own streams";
const offsetHoldsLoan = 'an offset account cannot hold a loan';
const offsetStandardOnly = 'offsetStreamIds is only for a loan';

/// 409 when [streamId] is a loan's offset account and so cannot receive a
/// loan (keeps the offset graph one level deep).
String offsetForMessage(String loanStreamName) =>
    'this stream is the offset account for $loanStreamName';

/// The caller's role on [streamId]: the authz middleware's, else looked up
/// (handlers mounted without it, as in route tests).
Future<Role?> callerRole(Session conn, Request request, String streamId) async {
  final r = accessOf(request)?.role;
  if (r != null) return r;
  final auth = authOf(request);
  if (auth == null) return null;
  return (await Authz(conn).stream(streamId, auth.user.id))?.role;
}

/// Parses `offsetStreamIds` of [body]: null when absent (unchanged).
List<String>? parseOffsetIds(Map<String, dynamic> body) {
  if (!body.containsKey('offsetStreamIds')) return null;
  final raw = body['offsetStreamIds'];
  if (raw == null) return const [];
  if (raw is! List) {
    throw const OffsetLinkError(400, 'offsetStreamIds must be an array');
  }
  final ids = <String>[];
  for (final v in raw) {
    if (v is! String || !uuidRe.hasMatch(v)) {
      throw const OffsetLinkError(400, 'offsetStreamIds must be stream ids');
    }
    if (!ids.contains(v)) ids.add(v);
  }
  return ids;
}

/// The name of a loan stream that uses [streamId] as its offset, if any.
Future<String?> offsetLoanStreamName(Session conn, String streamId) async {
  final r = await conn.execute(
    Sql.named('''
      SELECT s.name FROM events e JOIN streams s ON s.id = e.stream_id
      WHERE e.kind = 'loan' AND e.offset_stream_ids @> ARRAY[@a::uuid]
      ORDER BY s.name LIMIT 1
    '''),
    parameters: {'a': streamId},
  );
  return r.isEmpty ? null : r.first[0] as String;
}

/// Checks the offset link of a loan write (spec 004 rule 2) in the
/// request's transaction and returns the ids to store, or null to leave
/// them as they are. [kindIsLoan] / [terms] are the event after the write;
/// [existing] is null on create. Throws [OffsetLinkError].
Future<List<String>?> checkOffsetLink({
  required Session conn,
  required Request request,
  required BudgetStream loanStream,
  required Map<String, dynamic> body,
  required bool kindIsLoan,
  required LoanTerms? terms,
  BudgetEvent? existing,
}) async {
  final ids = parseOffsetIds(body);
  if (!kindIsLoan) {
    if (ids != null && ids.isNotEmpty) {
      throw const OffsetLinkError(400, offsetStandardOnly);
    }
    return null;
  }
  final current = existing?.offsetStreamIds ?? const <String>[];
  final next = ids ?? current;
  if (terms != null && terms.isFlat && next.isNotEmpty) {
    throw const OffsetLinkError(400, offsetFlatMessage);
  }
  if (ids == null) return null;
  final unchanged = ids.length == current.length && ids.every(current.contains);
  if (unchanged) return existing == null ? ids : null;
  if (await callerRole(conn, request, loanStream.id) != Role.owner) {
    throw const OffsetLinkError(403, offsetOwnerOnly);
  }
  await checkOffsetTargets(conn, loanStream, ids);
  return ids;
}

/// The target rules: at most one id, not the loan's own stream, a stream
/// the loan stream's owner owns (shared with them is not enough), holding
/// no loan. Locks the target rows for the rest of the transaction.
Future<void> checkOffsetTargets(
    Session conn, BudgetStream loanStream, List<String> ids) async {
  if (ids.length > 1) throw const OffsetLinkError(400, offsetMaxOne);
  for (final id in ids) {
    if (id == loanStream.id) throw const OffsetLinkError(400, offsetSelf);
    final r = await conn.execute(
      Sql.named('''
        SELECT owner_id::text,
               EXISTS (SELECT 1 FROM events e
                       WHERE e.stream_id = s.id AND e.kind = 'loan')
        FROM streams s WHERE s.id = @id::uuid FOR UPDATE
      '''),
      parameters: {'id': id},
    );
    // Missing and someone else's read the same (no existence leak).
    if (r.isEmpty || r.first[0] != loanStream.ownerId) {
      throw const OffsetLinkError(400, offsetOtherOwner);
    }
    if (r.first[1] == true) throw const OffsetLinkError(400, offsetHoldsLoan);
  }
}
