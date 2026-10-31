import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/authz.dart' show Authz, Role, uuidRe;
import '../repo/audit_repo.dart';
import '../auth/authz_middleware.dart';
import '../auth/middleware.dart';
import '../domain/models.dart';
import '../domain/event_import.dart';
import '../engine/calendar_math.dart';
import '../repo/stream_repo.dart';
import '../repo/category_repo.dart';
import '../repo/event_repo.dart';
import '../repo/trim_batch_repo.dart';
import 'balance.dart';
import 'categories.dart';
import 'json_helpers.dart';
import 'goal.dart';
import 'stream_view.dart';
import 'scenarios.dart';
import 'solve.dart';
import 'events.dart' show parseEventBody;
import 'loan_fields.dart';
import 'loan_summary.dart';
import '../domain/enums.dart' show EventKind;

/// All `/api/streams...` routes on one router (specific paths before `/<id>`).
Router buildStreamsApi(Session conn) {
  final streams = StreamRepo(conn);
  final events = EventRepo(conn);
  final router = Router();

  // Streams are top level: mine (owner) plus those shared with me.
  router.get('/', (Request request) async {
    final me = requireAuth(request).user.id;
    final items = await streams.listAccessible(me);
    final last = await streams.lastOpened(me);
    return jsonOk({
      'streams': items,
      // Only when still accessible (a share may have been revoked).
      'lastStreamId': items.any((a) => a['id'] == last) ? last : null,
    });
  });

  router.post('/', (Request request) async {
    try {
      final me = requireAuth(request).user.id;
      final body = await readJsonObject(request);
      final name = requireString(body, 'name').trim();
      if (name.isEmpty) return jsonError(400, 'name is required');
      // A 'currency' or 'projectId' field (older clients / exports) is
      // ignored: streams no longer have either.
      final seedBalance = parseDecimal(body['seedBalance'] ?? '0');
      final seedDate = parseDate(requireString(body, 'seedDate'));
      final lossThreshold = body.containsKey('lossThreshold')
          ? parseDecimal(body['lossThreshold'])
          : Decimal.zero;
      final stream = await streams.create(
        ownerId: me,
        name: name,
        seedBalance: seedBalance,
        seedDate: seedDate,
        lossThreshold: lossThreshold,
        displayOrder: optionalInt(body, 'displayOrder') ?? 0,
        // No explicit choice: Hundreds, like the dialog's preselected value.
        currencyScale:
            parseCurrencyScale(body) ?? BudgetStream.defaultCurrencyScale,
      );
      return jsonOk({...stream.toJson(), 'role': 'owner', 'shared': false},
          status: 201);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'you already have a stream with this name');
      }
      rethrow;
    }
  });

  router.get('/<streamId>/events', (Request request, String streamId) async {
    final stream = await streams.get(streamId);
    if (stream == null) return jsonError(404, 'stream not found');
    final items = await events.listByStream(streamId);
    return jsonOk({'events': items.map((s) => s.toJson()).toList()});
  });

  router.post('/<streamId>/events', (Request request, String streamId) async {
    try {
      final stream = await streams.get(streamId);
      if (stream == null) return jsonError(404, 'stream not found');

      final body = await readJsonObject(request);
      final loanKind = parseCreateKind(body);
      final parsed = parseEventBody(body);
      final loanTerms = loanKind.terms(parsed);
      if (loanKind.kind == EventKind.loan && stream.hasLoan) {
        return jsonError(409, streamHasLoan);
      }
      final transferTo = optionalString(body, 'transferToStreamId');
      final skips = (body['skippedDates'] as List?)
              ?.map((e) => parseDate(e.toString()))
              .toList() ??
          const <DateTime>[];
      // A transfer creates both sides atomically.
      final event = await txOf(conn).runTx((tx) async {
        final events = EventRepo(tx);
        final name = await resolveEventCategory(tx, streamId, body,
            legacyName: parsed.name);
        var created = await events.create(
          streamId: streamId,
          name: name ?? parsed.name,
          direction: parsed.direction,
          amount: parsed.amount,
          startDate: parsed.startDate,
          recurrenceMode: parsed.recurrenceMode,
          interval: parsed.interval,
          unit: parsed.unit,
          days: parsed.days,
          endMode: parsed.endMode,
          endDate: parsed.endDate,
          occurrenceCount: parsed.occurrenceCount,
          enabled: parsed.enabled,
          color: parsed.color,
          kind: loanKind.kind,
          loan: loanTerms,
        );
        for (final d in skips) {
          await events.setSkip(created.id, d, true);
        }
        if (transferTo != null) {
          created = await events.linkNewPeer(created, transferTo);
        }
        return created;
      });
      return jsonOk(event.toJson(), status: 201);
    } on ServerException catch (e) {
      // A concurrent create raced past the hasLoan check.
      if (e.constraintName == 'events_one_loan_per_stream') {
        return jsonError(409, streamHasLoan);
      }
      rethrow;
    } on CategoryNameException catch (e) {
      return categoryNameError(e);
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });

  // Bulk import (see docs in event_import.dart). `?root=YYYY-MM-DD`
  // (required) is the selected timeline day all day offsets count from.
  // Body: the raw paste —
  // a JSON array of EventImport, a single object, or either wrapped in
  // a ```json fence. `?dryRun=true` validates and returns the preview only.
  // All-or-nothing: any invalid item -> 400 with per-item `issues`, nothing
  // written. Items whose `id` already exists in this stream are skipped.
  router.post('/<streamId>/events/import',
      (Request request, String streamId) async {
    final stream = await streams.get(streamId);
    if (stream == null) return jsonError(404, 'stream not found');
    final dryRun = request.url.queryParameters['dryRun'] == 'true';
    final root = parseImportRoot(request.url.queryParameters['root']);
    final raw = await request.readAsString();
    try {
      if (root == null) {
        throw ImportValidationException([
          ImportIssue(
              null,
              'root',
              'Select a day on the timeline first: offsets count from it '
                  '(?root=YYYY-MM-DD)')
        ]);
      }
      final items = parseImport(raw, root: root);
      if (dryRun) {
        final existing =
            (await events.listByStream(streamId)).map((t) => t.id).toSet();
        final dupes = [
          for (final i in items)
            if (i.id != null && existing.contains(i.id)) i.index
        ];
        return jsonOk({
          'dryRun': true,
          'items': items
              .map((i) => {...i.toJson(), 'exists': dupes.contains(i.index)})
              .toList(),
          'toCreate': items.length - dupes.length,
          'toSkip': dupes.length,
        });
      }
      final result = await txOf(conn)
          .runTx((tx) => EventRepo(tx).importItems(streamId, items));
      return jsonOk({
        'created': result.created.length,
        'skipped': result.skipped.length,
        'createdIds': result.created,
        'skippedIds': result.skipped,
      }, status: result.created.isEmpty ? 200 : 201);
    } on ImportValidationException catch (e) {
      return jsonError(400,
          'Import rejected: ${e.issues.length} problem(s); nothing was imported',
          details: e.issues
              .map((i) => {...i.toJson(), 'text': i.toString()})
              .toList());
    }
  });

  // Undo of an import. Body: {"ids": [...]} (the import's createdIds).
  // One DB transaction: every listed row still in this stream goes, or none
  // does. Ids already gone (deleted / never in this stream) are reported as
  // `missing`, not an error, so a retry after a partial outcome is safe.
  router.post('/<streamId>/events/import/undo',
      (Request request, String streamId) async {
    final stream = await streams.get(streamId);
    if (stream == null) return jsonError(404, 'stream not found');
    final List<String> ids;
    try {
      final raw = (await readJsonObject(request))['ids'];
      if (raw is! List ||
          raw.isEmpty ||
          raw.length > 5000 ||
          raw.any((e) => e is! String || !uuidRe.hasMatch(e))) {
        return jsonError(400, 'ids must be a non-empty array of UUIDs');
      }
      ids = {for (final e in raw) (e as String).toLowerCase()}.toList();
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
    final result = await txOf(conn)
        .runTx((tx) => EventRepo(tx).deleteImported(streamId, ids));
    return jsonOk({
      'deleted': result.deleted.length,
      'deletedIds': result.deleted,
      'missing': result.missing,
    });
  });

  // The day pick's ✂: end every event on one day, atomically (see
  // TrimBatchRepo.endAllOn). Body: {"date": "YYYY-MM-DD", "ids"?: [...]}
  // (ids: only those, the list the user confirmed). Returns the batch id
  // for Undo and what was ended / deleted / left alone.
  router.post('/<streamId>/events/trim',
      (Request request, String streamId) async {
    final stream = await streams.get(streamId);
    if (stream == null) return jsonError(404, 'stream not found');
    final me = requireAuth(request).user.id;
    final DateTime day;
    Set<String>? ids;
    try {
      final body = await readJsonObject(request);
      day = parseDate(requireString(body, 'date'));
      final raw = body['ids'];
      if (raw != null) {
        if (raw is! List ||
            raw.length > 5000 ||
            raw.any((e) => e is! String || !uuidRe.hasMatch(e))) {
          return jsonError(400, 'ids must be an array of UUIDs');
        }
        ids = {for (final e in raw) (e as String).toLowerCase()};
      }
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
    // Which of the transfers' other streams I can edit (asked before the
    // batch's transaction).
    final authz = Authz(conn);
    final editable = <String>{};
    for (final t in await events.listByStream(streamId)) {
      final sid = t.transfer?.peerStreamId;
      if (sid == null || editable.contains(sid)) continue;
      final a = await authz.stream(sid, me);
      if (a?.role != null && a!.role!.atLeast(Role.editor)) editable.add(sid);
    }
    final peerStreams = <String>{};
    final r = await txOf(conn).runTx((tx) => TrimBatchRepo(tx).endAllOn(
          streamId,
          day,
          userId: me,
          ids: ids,
          canEdit: (sid) async {
            final ok = editable.contains(sid);
            if (ok) peerStreams.add(sid);
            return ok;
          },
        ));
    await notifyPeers(conn, request, me, peerStreams, 'events.trimmed');
    return jsonOk({'date': formatDate(day), ...r.toJson()});
  });

  // Undo of a trim batch: everything it ended or deleted comes back.
  router.post('/<streamId>/events/trim/undo',
      (Request request, String streamId) async {
    final me = requireAuth(request).user.id;
    final String batchId;
    try {
      batchId = requireString(await readJsonObject(request), 'batchId');
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
    if (!uuidRe.hasMatch(batchId)) return jsonError(400, 'bad batchId');
    final r = await txOf(conn)
        .runTx((tx) => TrimBatchRepo(tx).undo(streamId, batchId, me));
    if (r == null) return jsonError(404, 'nothing to undo');
    final peers = await conn.execute(
      Sql.named('SELECT DISTINCT stream_id::text FROM events '
          'WHERE id = ANY (@ids::uuid[]) AND stream_id <> @a::uuid'),
      parameters: {'ids': r.restored, 'a': streamId},
    );
    await notifyPeers(conn, request, me,
        {for (final p in peers) p[0] as String}, 'events.trim_undone');
    return jsonOk({'restored': r.restored.length});
  });

  attachBalanceRoutes(router, conn);
  attachLoanSummaryRoute(router, conn);
  attachCategoryRoutes(router, conn);
  attachSolveRoutes(router, conn);
  attachGoalRoutes(router, conn);
  attachStreamViewRoutes(router, conn);
  attachScenarioRoutes(router, conn);

  router.patch('/<id>/reorder-events', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final raw = body['eventIds'];
      if (raw is! List) {
        return jsonError(400, 'eventIds must be an array');
      }
      final eventIds = raw.map((e) => e.toString()).toList();
      final stream = await streams.reorderEvents(id, eventIds);
      if (stream == null) return jsonError(404, 'stream not found');
      return jsonOk(stream.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    }
  });

  /// `POST /<id>/opened`: the timeline was opened (any role). The next
  /// sign-in lands here.
  router.post('/<id>/opened', (Request request, String id) async {
    final auth = authOf(request);
    if (auth != null) await streams.markOpened(auth.user.id, id);
    return jsonOk({'lastStreamId': id});
  });

  router.get('/<id>', (Request request, String id) async {
    final stream = await streams.get(id);
    if (stream == null) return jsonError(404, 'stream not found');
    final access = accessOf(request);
    // Remember it: sign-in lands on the stream opened last.
    final auth = authOf(request);
    if (auth != null) await streams.markOpened(auth.user.id, id);
    return jsonOk({
      ...stream.toJson(),
      if (access?.role != null) 'role': access!.role!.name,
      'shared': access?.isOwner == false,
    });
  });

  router.patch('/<id>', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      final newSeed = body.containsKey('seedDate')
          ? parseDate(requireString(body, 'seedDate'))
          : null;
      // Seed date change moves every schedule by the same calendar-day
      // delta, atomically with the stream update.
      final stream = await txOf(conn).runTx((tx) async {
        final repo = StreamRepo(tx);
        final before = await repo.get(id);
        if (before == null) return null;
        final updated = await repo.update(
          id,
          name: optionalString(body, 'name'),
          seedBalance: body.containsKey('seedBalance')
              ? parseDecimal(body['seedBalance'])
              : null,
          lossThreshold: body.containsKey('lossThreshold')
              ? parseDecimal(body['lossThreshold'])
              : null,
          seedDate: newSeed,
          displayOrder: optionalInt(body, 'displayOrder'),
          currencyScale: parseCurrencyScale(body),
        );
        if (newSeed != null) {
          await repo.shiftSchedules(
            id,
            calendarDayDelta(before.seedDate, newSeed),
          );
        }
        return updated;
      });
      if (stream == null) return jsonError(404, 'stream not found');
      return jsonOk(stream.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on ServerException catch (e) {
      if (e.code == '23505') {
        return jsonError(409, 'you already have a stream with this name');
      }
      rethrow;
    }
  });

  // Deleting a stream: its own events go with it; the far side of each
  // of its transfers (in other streams) is kept as a plain event
  // (`?transfers=keep`, the default) or deleted (`?transfers=delete`, which
  // needs editor on every such stream). Never left pointing at a missing
  // stream. All in the request's DB transaction.
  router.delete('/<id>', (Request request, String id) async {
    final mode =
        TransferDeleteMode.parse(request.url.queryParameters['transfers']);
    if (mode == null) {
      return jsonError(400, 'transfers must be keep or delete');
    }
    final me = requireAuth(request).user.id;
    final peers = await streams.transferPeers(id);
    final peerStreams = {for (final p in peers) p.peerStreamId};
    if (mode == TransferDeleteMode.delete) {
      final authz = Authz(conn);
      final blocked = <String>[];
      for (final pid in peerStreams) {
        final a = await authz.stream(pid, me);
        if (a?.role == null || !a!.role!.atLeast(Role.editor)) blocked.add(pid);
      }
      if (blocked.isNotEmpty) {
        return jsonError(
          403,
          'deleting the transfers needs editor access to every stream they '
          'are in; keep them instead',
          details: {'streams': blocked},
        );
      }
    }
    final r = await streams.delete(id, transfers: mode);
    if (!r.deleted) return jsonError(404, 'stream not found');
    // The surviving streams changed too: tell their viewers (real-time).
    final audit = AuditRepo(conn);
    for (final pid in peerStreams) {
      final ids = [
        for (final p in peers)
          if (p.peerStreamId == pid) p.peerId
      ];
      await audit.record(
        userId: me,
        action: mode == TransferDeleteMode.keep
            ? 'events.transfers_unlinked'
            : 'events.transfers_deleted',
        streamId: pid,
        clientId: request.headers['x-client-id'],
        detail: {'deletedStreamId': id, 'ids': ids},
      );
    }
    return jsonOk({
      'deleted': true,
      'transfers': mode.name,
      'converted': r.converted.length,
      'removed': r.removed.length,
      'affectedStreams': peerStreams.toList(),
    });
  });

  return router;
}

/// Audit rows (and so real-time updates) for the other streams a batch
/// changed through transfers.
/// Audit [action] in each of [streamIds] (a transfer's other side changed
/// there) so its live clients refresh.
Future<void> notifyPeers(Session conn, Request request, String me,
    Set<String> streamIds, String action) async {
  final audit = AuditRepo(conn);
  for (final sid in streamIds) {
    await audit.record(
      userId: me,
      action: action,
      streamId: sid,
      clientId: request.headers['x-client-id'],
      detail: const {'via': 'transfer'},
    );
  }
}
