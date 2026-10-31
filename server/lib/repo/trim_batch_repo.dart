import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../engine/occurrence_gen.dart';
import 'event_repo.dart';

/// What "end every event on [day]" does to one event.
enum EndOnDay {
  /// The series ends on the day (inclusive): its later occurrences go.
  end,

  /// It starts after the day, so nothing of it would remain: deleted.
  delete,
}

DateTime _d(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// [t] under "end every event on [day]" (end dates are inclusive, so
/// [day]'s own occurrence stays): null when nothing of [t] falls after
/// [day] (or it is disabled), [EndOnDay.delete] when it first fires after
/// [day], else [EndOnDay.end].
EndOnDay? endOnDayPlan(BudgetEvent t, DateTime day) {
  if (!t.active) return null;
  final d = _d(day);
  final start = _d(t.startDate);
  // "Starts" = first fires: a weekly Mon/Tue series that begins on a
  // Thursday starts the next Monday.
  final first = OccurrenceGenerator.nthDate(t, 1) ?? start;
  if (first.isAfter(d)) return EndOnDay.delete;
  if (t.recurrenceMode != RecurrenceMode.every) return null;
  switch (t.endMode) {
    case EndMode.never:
      return EndOnDay.end;
    case EndMode.untilDate:
      return t.endDate != null && _d(t.endDate!).isAfter(d)
          ? EndOnDay.end
          : null;
    case EndMode.count:
      final dates =
          OccurrenceGenerator.datesForEvent(t, start, DateTime.utc(3000));
      return dates.any((x) => _d(x).isAfter(d)) ? EndOnDay.end : null;
  }
}

class TrimBatchResult {
  TrimBatchResult({
    required this.batchId,
    required this.ended,
    required this.deleted,
    required this.blocked,
  });

  /// Null when nothing was changed (no batch to undo).
  final String? batchId;
  final List<String> ended;
  final List<String> deleted;

  /// Transfers left alone: the caller cannot edit the other side's stream.
  final List<String> blocked;

  Map<String, Object?> toJson() => {
        'batchId': batchId,
        'ended': ended,
        'deleted': deleted,
        'blocked': blocked,
      };
}

/// "End every event on this day" as one atomic, undoable batch.
class TrimBatchRepo {
  TrimBatchRepo(this._conn) : _events = EventRepo(_conn);

  final Session _conn;
  final EventRepo _events;

  /// Ends every event of [streamId] (only [ids] when given) on [day] per
  /// [endOnDayPlan]: series end on [day], events starting after it are
  /// deleted (with a transfer's other side). A transfer whose other stream
  /// [canEdit] refuses is left alone (`blocked`). Snapshots every affected
  /// row first so [undo] can restore all of it. Call inside one DB
  /// transaction.
  Future<TrimBatchResult> endAllOn(
    String streamId,
    DateTime day, {
    required String userId,
    Set<String>? ids,
    required Future<bool> Function(String streamId) canEdit,
  }) async {
    final d = _d(day);
    final plans = <BudgetEvent, EndOnDay>{};
    final blocked = <String>[];
    for (final t in await _events.listByStream(streamId)) {
      if (ids != null && !ids.contains(t.id)) continue;
      final plan = endOnDayPlan(t, d);
      if (plan == null) continue;
      final peerStream = t.transfer?.peerStreamId;
      if (t.transfer?.peerId != null &&
          peerStream != null &&
          !await canEdit(peerStream)) {
        blocked.add(t.id);
        continue;
      }
      plans[t] = plan;
    }
    if (plans.isEmpty) {
      return TrimBatchResult(
          batchId: null, ended: [], deleted: [], blocked: blocked);
    }
    final affected = {
      for (final t in plans.keys) ...[
        t.id,
        if (t.transfer?.peerId != null) t.transfer!.peerId!,
      ],
    }.toList();
    final snapshot = await _snapshot(affected);

    final ended = <String>[], deleted = <String>[];
    for (final MapEntry(key: t, value: plan) in plans.entries) {
      if (plan == EndOnDay.delete) {
        await _events.delete(t.id);
        deleted.add(t.id);
      } else {
        final updated = (await _events.update(t.id,
            endMode: EndMode.untilDate,
            endDate: d,
            clearOccurrenceCount: true))!;
        await _events.pruneOverrides(t.id);
        await _events.syncPeer(updated);
        ended.add(t.id);
      }
    }
    final batchId = const Uuid().v4();
    await _conn.execute(
      Sql.named('''
        INSERT INTO event_trim_batches (id, stream_id, user_id, day, snapshot)
        VALUES (@id::uuid, @a::uuid, @u::uuid, @d, @s::jsonb)
      '''),
      parameters: {
        'id': batchId,
        'a': streamId,
        'u': userId,
        'd': d,
        's': jsonEncode({
          ...snapshot,
          'ended': ended,
          'deleted': deleted,
        }),
      },
    );
    return TrimBatchResult(
        batchId: batchId, ended: ended, deleted: deleted, blocked: blocked);
  }

  /// Deletes [ids] (events of [streamId], or of any stream when
  /// [anyStream]: the caller checked access; each transfer's other side goes
  /// with it) as one undoable batch, like [endAllOn]'s deletions: [undo]
  /// brings them back with the same ids, skips, overrides and list
  /// positions. Returns the batch id (null when nothing was deleted) and
  /// the deleted ids, peers included. Call inside one DB transaction.
  Future<({String? batchId, List<String> deleted, Set<String> peerStreams})>
      deleteAsBatch(String streamId, List<String> ids,
          {required String userId, bool anyStream = false}) async {
    final targets = <BudgetEvent>[];
    final seen = <String>{};
    for (final id in ids) {
      if (seen.contains(id)) continue;
      final t = await _events.get(id);
      if (t == null || (!anyStream && t.streamId != streamId)) continue;
      targets.add(t);
      seen.add(t.id);
      if (t.transfer?.peerId != null) seen.add(t.transfer!.peerId!);
    }
    if (targets.isEmpty) {
      return (batchId: null, deleted: <String>[], peerStreams: <String>{});
    }
    final snapshot = await _snapshot(seen.toList());
    final deleted = <String>[];
    final peerStreams = <String>{};
    for (final t in targets) {
      if (t.streamId != streamId) peerStreams.add(t.streamId);
      if (await _events.delete(t.id)) deleted.add(t.id);
      final peer = t.transfer?.peerId;
      if (peer != null) {
        deleted.add(peer);
        final ps = t.transfer?.peerStreamId;
        if (ps != null && ps != streamId) peerStreams.add(ps);
      }
    }
    final batchId = const Uuid().v4();
    await _conn.execute(
      Sql.named('''
        INSERT INTO event_trim_batches (id, stream_id, user_id, day, snapshot)
        VALUES (@id::uuid, @a::uuid, @u::uuid, @d, @s::jsonb)
      '''),
      parameters: {
        'id': batchId,
        'a': streamId,
        'u': userId,
        'd': _d(DateTime.now()),
        's': jsonEncode({...snapshot, 'ended': <String>[], 'deleted': deleted}),
      },
    );
    return (batchId: batchId, deleted: deleted, peerStreams: peerStreams);
  }

  /// The rows [ids] as stored (whole rows), their skips and overrides, and
  /// the event order of every stream they are in.
  Future<Map<String, Object?>> _snapshot(List<String> ids) async {
    final rows = await _conn.execute(
      Sql.named('SELECT to_jsonb(e.*)::text FROM events e '
          'WHERE e.id = ANY (@ids::uuid[])'),
      parameters: {'ids': ids},
    );
    final skips = await _conn.execute(
      Sql.named("SELECT event_id::text, to_char(date, 'YYYY-MM-DD') "
          'FROM skipped_occurrences WHERE event_id = ANY (@ids::uuid[])'),
      parameters: {'ids': ids},
    );
    final overrides = await _conn.execute(
      Sql.named("SELECT event_id::text, to_char(date, 'YYYY-MM-DD'), "
          'amount::text, direction FROM occurrence_overrides '
          'WHERE event_id = ANY (@ids::uuid[])'),
      parameters: {'ids': ids},
    );
    final orders = await _conn.execute(
      Sql.named('''
        SELECT s.id::text, COALESCE(s.event_order::text[], '{}')
        FROM streams s
        WHERE s.id IN (SELECT stream_id FROM events WHERE id = ANY (@ids::uuid[]))
      '''),
      parameters: {'ids': ids},
    );
    return {
      'rows': [for (final r in rows) jsonDecode(r[0] as String)],
      'skips': [
        for (final r in skips) {'event': r[0], 'date': r[1]},
      ],
      'overrides': [
        for (final r in overrides)
          {'event': r[0], 'date': r[1], 'amount': r[2], 'direction': r[3]},
      ],
      'orders': {
        for (final r in orders) r[0] as String: (r[1] as List).cast<String>(),
      },
    };
  }

  /// Restores batch [batchId] of [streamId] made by [userId]: deleted rows
  /// come back (same ids, skips, overrides, list positions), ended series
  /// get their old end and overrides back (and their transfer peers).
  /// Returns null when there is no such batch (or it was undone already /
  /// is older than a day). Call inside one DB transaction.
  Future<({List<String> restored})?> undo(
      String streamId, String batchId, String userId) async {
    final found = await _conn.execute(
      Sql.named('''
        UPDATE event_trim_batches SET undone_at = now()
        WHERE id = @id::uuid AND stream_id = @a::uuid AND user_id = @u::uuid
          AND undone_at IS NULL AND created_at > now() - interval '1 day'
        RETURNING snapshot::text
      '''),
      parameters: {'id': batchId, 'a': streamId, 'u': userId},
    );
    if (found.isEmpty) return null;
    final snap = jsonDecode(found.first[0] as String) as Map<String, dynamic>;
    final rows = (snap['rows'] as List).cast<Map<String, dynamic>>();
    final ids = [for (final r in rows) r['id'] as String];
    final present = {
      for (final r in await _conn.execute(
        Sql.named('SELECT id::text FROM events WHERE id = ANY (@ids::uuid[])'),
        parameters: {'ids': ids},
      ))
        r[0] as String,
    };
    for (final r in rows) {
      final row = jsonEncode(r);
      if (present.contains(r['id'])) {
        // Ended: back to its old end (the rest of the row is as edited).
        await _conn.execute(
          Sql.named('''
            UPDATE events e SET end_mode = r.end_mode, end_date = r.end_date,
              occurrence_count = r.occurrence_count
            FROM jsonb_populate_record(NULL::events, @row::jsonb) r
            WHERE e.id = r.id
          '''),
          parameters: {'row': row},
        );
      } else {
        await _conn.execute(
          Sql.named('INSERT INTO events '
              'SELECT r.* FROM jsonb_populate_record(NULL::events, @row::jsonb) r '
              // (Not into a stream deleted since.)
              'WHERE EXISTS (SELECT 1 FROM streams s WHERE s.id = r.stream_id)'),
          parameters: {'row': row},
        );
      }
    }
    // Spec 004 rule 4: a restored loan keeps only offset streams that
    // still exist, are still its owner's and hold no loan.
    await _conn.execute(
      Sql.named('''
        UPDATE events e SET offset_stream_ids = ARRAY(
          SELECT x FROM unnest(e.offset_stream_ids) AS x
          WHERE EXISTS (
            SELECT 1 FROM streams o JOIN streams l ON l.id = e.stream_id
            WHERE o.id = x AND o.id <> l.id AND o.owner_id = l.owner_id
              AND NOT EXISTS (SELECT 1 FROM events k
                              WHERE k.stream_id = o.id AND k.kind = 'loan')))
        WHERE e.id = ANY (@ids::uuid[]) AND cardinality(e.offset_stream_ids) > 0
      '''),
      parameters: {'ids': ids},
    );
    await _conn.execute(
      Sql.named('DELETE FROM occurrence_overrides '
          'WHERE event_id = ANY (@ids::uuid[])'),
      parameters: {'ids': ids},
    );
    for (final o in (snap['overrides'] as List).cast<Map<String, dynamic>>()) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO occurrence_overrides (event_id, date, amount, direction)
          SELECT @t::uuid, @d::date, @amount::numeric, @dir
          WHERE EXISTS (SELECT 1 FROM events WHERE id = @t::uuid)
        '''),
        parameters: {
          't': o['event'],
          'd': o['date'],
          'amount': o['amount'],
          'dir': o['direction'],
        },
      );
    }
    for (final s in (snap['skips'] as List).cast<Map<String, dynamic>>()) {
      await _conn.execute(
        Sql.named('INSERT INTO skipped_occurrences (event_id, date) '
            'SELECT @t::uuid, @d::date '
            'WHERE EXISTS (SELECT 1 FROM events WHERE id = @t::uuid) '
            'ON CONFLICT DO NOTHING'),
        parameters: {'t': s['event'], 'd': s['date']},
      );
    }
    // Each stream's order: the old order (rows that exist now), then
    // anything added since, in its current order.
    final orders = (snap['orders'] as Map<String, dynamic>);
    for (final MapEntry(key: sid, value: old) in orders.entries) {
      final cur = await _conn.execute(
        Sql.named('''
          SELECT COALESCE(event_order::text[], '{}'),
            ARRAY(SELECT id::text FROM events WHERE stream_id = @a::uuid)
          FROM streams WHERE id = @a::uuid
        '''),
        parameters: {'a': sid},
      );
      if (cur.isEmpty) continue;
      final current = (cur.first[0] as List).cast<String>();
      final live = (cur.first[1] as List).cast<String>().toSet();
      final oldOrder = (old as List).cast<String>();
      final next = [
        for (final x in oldOrder)
          if (live.contains(x)) x,
        for (final x in current)
          if (!oldOrder.contains(x) && live.contains(x)) x,
      ];
      await _conn.execute(
        Sql.named('UPDATE streams SET event_order = @o::uuid[] '
            'WHERE id = @a::uuid'),
        parameters: {'a': sid, 'o': next},
      );
    }
    return (restored: ids);
  }

  /// Drops batches older than a day (their Undo is long gone).
  Future<int> purgeOld() async {
    final r = await _conn.execute(
      "DELETE FROM event_trim_batches WHERE created_at < now() - interval '1 day' "
      'RETURNING 1',
    );
    return r.length;
  }
}
