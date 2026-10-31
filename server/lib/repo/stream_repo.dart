import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

class StreamRepo {
  StreamRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  /// Streams [userId] owns or has been shared, with their role, owner and
  /// whether they are shared with them. Mine first (display order, name),
  /// then shared ones by name.
  Future<List<Map<String, Object?>>> listAccessible(String userId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT a.id, a.owner_id, a.name, a.seed_balance, a.seed_date,
               a.loss_threshold, a.display_order, a.event_order,
               a.currency_scale, a.version,
               CASE WHEN a.owner_id = @u::uuid THEN 'owner' ELSE s.role::text END,
               u.email, u.name, u.picture_url,
               EXISTS (SELECT 1 FROM events e WHERE e.stream_id = a.id
                       AND e.kind = 'loan') AS has_loan
        FROM streams a
        JOIN users u ON u.id = a.owner_id
        LEFT JOIN stream_shares s
          ON s.stream_id = a.id AND s.user_id = @u::uuid
        WHERE a.owner_id = @u::uuid OR s.user_id IS NOT NULL
        ORDER BY (a.owner_id = @u::uuid) DESC,
                 CASE WHEN a.owner_id = @u::uuid THEN a.display_order ELSE 0 END,
                 lower(a.name), a.id
      '''),
      parameters: {'u': userId},
    );
    return rows.map((r) {
      final shared = r[1].toString() != userId;
      return {
        ..._fromRow(r).toJson(),
        'role': r[10],
        'shared': shared,
        'owner': {
          'id': r[1].toString(),
          'email': r[11],
          'name': r[12],
          'pictureUrl': r[13],
        },
      };
    }).toList();
  }

  /// The stream [userId] opened last (may no longer be accessible).
  Future<String?> lastOpened(String userId) async {
    final r = await _conn.execute(
      Sql.named('SELECT last_stream_id::text FROM users WHERE id = @u::uuid'),
      parameters: {'u': userId},
    );
    return r.isEmpty ? null : r.first[0] as String?;
  }

  Future<void> markOpened(String userId, String streamId) async {
    await _conn.execute(
      Sql.named('UPDATE users SET last_stream_id = @a::uuid '
          'WHERE id = @u::uuid AND last_stream_id IS DISTINCT FROM @a::uuid'),
      parameters: {'u': userId, 'a': streamId},
    );
  }

  Future<BudgetStream?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, owner_id, name, seed_balance, seed_date,
               loss_threshold, display_order, event_order, currency_scale, version,
               EXISTS (SELECT 1 FROM events e WHERE e.stream_id = streams.id AND e.kind = 'loan') AS has_loan
        FROM streams WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<BudgetStream> create({
    required String ownerId,
    required String name,
    required Decimal seedBalance,
    required DateTime seedDate,
    required Decimal lossThreshold,
    int displayOrder = 0,
    int currencyScale = BudgetStream.defaultCurrencyScale,
  }) async {
    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO streams (
          id, owner_id, name, seed_balance, seed_date,
          loss_threshold, display_order, currency_scale, created_by
        ) VALUES (
          @id, @ownerId::uuid, @name, @seedBalance, @seedDate,
          @lossThreshold, @displayOrder, @currencyScale, @ownerId::uuid
        )
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, event_order, currency_scale, version,
                  EXISTS (SELECT 1 FROM events e WHERE e.stream_id = streams.id AND e.kind = 'loan') AS has_loan
      '''),
      parameters: {
        'id': id,
        'ownerId': ownerId,
        'name': name,
        'seedBalance': seedBalance.toString(),
        'seedDate': DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
        'lossThreshold': lossThreshold.toString(),
        'displayOrder': displayOrder,
        'currencyScale': currencyScale,
      },
    );
    return _fromRow(rows.first);
  }

  Future<BudgetStream?> update(
    String id, {
    String? name,
    Decimal? seedBalance,
    DateTime? seedDate,
    Decimal? lossThreshold,
    int? displayOrder,
    int? currencyScale,
  }) async {
    final existing = await get(id);
    if (existing == null) return null;

    final rows = await _conn.execute(
      Sql.named('''
        UPDATE streams SET
          name = @name,
          seed_balance = @seedBalance,
          seed_date = @seedDate,
          loss_threshold = @lossThreshold,
          display_order = @displayOrder,
          currency_scale = @currencyScale
        WHERE id = @id
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, event_order, currency_scale, version,
                  EXISTS (SELECT 1 FROM events e WHERE e.stream_id = streams.id AND e.kind = 'loan') AS has_loan
      '''),
      parameters: {
        'id': id,
        'name': name ?? existing.name,
        'seedBalance': (seedBalance ?? existing.seedBalance).toString(),
        'lossThreshold': (lossThreshold ?? existing.lossThreshold).toString(),
        'seedDate': seedDate == null
            ? DateTime.utc(
                existing.seedDate.year,
                existing.seedDate.month,
                existing.seedDate.day,
              )
            : DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
        'displayOrder': displayOrder ?? existing.displayOrder,
        'currencyScale': currencyScale ?? existing.currencyScale,
      },
    );
    return _fromRow(rows.first);
  }

  /// Moves every event schedule of [streamId] by [days] calendar
  /// days (start date, until-date end, skipped dates) so the schedule keeps
  /// its position relative to the seed date. Run inside the same DB
  /// event as the seed-date update. Returns the number of
  /// events moved.
  Future<int> shiftSchedules(String streamId, int days) async {
    if (days == 0) return 0;
    // Transfers move as a pair: the peer row in the other stream shifts
    // with its source so both sides keep the same dates.
    const scope = '''
      stream_id = @id OR transfer_id IN (
        SELECT transfer_id FROM events
        WHERE stream_id = @id AND transfer_id IS NOT NULL)''';
    final moved = await _conn.execute(
      Sql.named('''
        UPDATE events SET
          start_date = start_date + @d::int,
          end_date = CASE WHEN end_date IS NULL THEN NULL ELSE end_date + @d::int END
        WHERE $scope
        RETURNING stream_id = @id
      '''),
      parameters: {'id': streamId, 'd': days},
    );
    // Skipped dates: delete + re-insert, so a uniform shift can't trip the
    // (event_id, date) primary key mid-update.
    final skipped = await _conn.execute(
      Sql.named('''
        DELETE FROM skipped_occurrences
        WHERE event_id IN (SELECT id FROM events WHERE $scope)
        RETURNING event_id::text, date
      '''),
      parameters: {'id': streamId},
    );
    for (final row in skipped) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO skipped_occurrences (event_id, date)
          VALUES (@t::uuid, @date::date + @d::int)
        '''),
        parameters: {'t': row[0], 'date': row[1], 'd': days},
      );
    }
    // Once-off overrides move with their occurrences, the same way.
    final overrides = await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE event_id IN (SELECT id FROM events WHERE $scope)
        RETURNING event_id::text, date, amount::text, direction
      '''),
      parameters: {'id': streamId},
    );
    for (final row in overrides) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO occurrence_overrides (event_id, date, amount, direction)
          VALUES (@t::uuid, @date::date + @d::int, @amount::numeric, @dir)
        '''),
        parameters: {
          't': row[0],
          'date': row[1],
          'd': days,
          'amount': row[2],
          'dir': row[3],
        },
      );
    }
    return moved.where((r) => r[0] == true).length;
  }

  Future<BudgetStream?> reorderEvents(String id, List<String> eventIds) async {
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE streams SET event_order = COALESCE((
          -- Only this stream's own events, first mention wins.
          SELECT array_agg(x.id ORDER BY x.ord) FROM (
            SELECT DISTINCT ON (t.id) t.id, u.ord
            FROM unnest(@eventOrder::text[]) WITH ORDINALITY u(v, ord)
            JOIN events t
              ON t.id::text = lower(u.v) AND t.stream_id = streams.id
            ORDER BY t.id, u.ord) x), '{}')
        WHERE id = @id
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, event_order, currency_scale, version,
                  EXISTS (SELECT 1 FROM events e WHERE e.stream_id = streams.id AND e.kind = 'loan') AS has_loan
      '''),
      parameters: {
        'id': id,
        'eventOrder': eventIds,
      },
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Transfers between [streamId] and other streams: one row per peer (the
  /// surviving side), with its stream. Read before a delete.
  Future<List<({String peerId, String peerStreamId})>> transferPeers(
      String streamId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT p.id::text, p.stream_id::text FROM events p
        JOIN events t ON t.transfer_id = p.transfer_id AND t.id <> p.id
        WHERE t.stream_id = @a::uuid AND t.transfer_id IS NOT NULL
          AND p.stream_id <> @a::uuid
        ORDER BY p.stream_id, p.id
      '''),
      parameters: {'a': streamId},
    );
    return [
      for (final r in rows)
        (peerId: r[0] as String, peerStreamId: r[1] as String)
    ];
  }

  /// Deletes the stream and its own events (cascade). Its transfers'
  /// far sides in other streams never dangle: [transfers] keep turns each
  /// into a plain event of its stream (same name, direction, amount,
  /// schedule, skips, overrides, enabled: that stream's balance is
  /// unchanged); delete removes them. Call inside a DB transaction.
  Future<({bool deleted, List<String> converted, List<String> removed})> delete(
      String id,
      {TransferDeleteMode transfers = TransferDeleteMode.keep}) async {
    final peers = await transferPeers(id);
    final ids = [for (final p in peers) p.peerId];
    final converted = <String>[], removed = <String>[];
    if (ids.isNotEmpty) {
      if (transfers == TransferDeleteMode.keep) {
        final rows = await _conn.execute(
          Sql.named('''
            UPDATE events
            SET transfer_id = NULL, version = version + 1, updated_at = now()
            WHERE id = ANY(@ids::uuid[]) RETURNING id::text
          '''),
          parameters: {'ids': ids},
        );
        converted.addAll(rows.map((r) => r[0] as String));
      } else {
        await _conn.execute(
          Sql.named('''
            UPDATE streams p SET event_order = COALESCE((
              SELECT array_agg(x ORDER BY o) FROM unnest(p.event_order)
                WITH ORDINALITY AS u(x, o)
              WHERE NOT (x = ANY(@ids::uuid[]))), '{}')
            WHERE p.id IN (SELECT stream_id FROM events
                           WHERE id = ANY(@ids::uuid[]))
          '''),
          parameters: {'ids': ids},
        );
        final rows = await _conn.execute(
          Sql.named('DELETE FROM events WHERE id = ANY(@ids::uuid[]) '
              'RETURNING id::text'),
          parameters: {'ids': ids},
        );
        removed.addAll(rows.map((r) => r[0] as String));
      }
    }
    final rows = await _conn.execute(
      Sql.named('DELETE FROM streams WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return (deleted: rows.isNotEmpty, converted: converted, removed: removed);
  }

  BudgetStream _fromRow(ResultRow row) {
    final seedBalanceRaw = row[3];
    final eventOrderRaw = row[7];
    final List<String> eventOrder;
    if (eventOrderRaw == null) {
      eventOrder = const [];
    } else if (eventOrderRaw is List) {
      eventOrder = eventOrderRaw.map((e) => e.toString()).toList();
    } else {
      eventOrder = const [];
    }

    final seedDate = row[4] as DateTime;
    return BudgetStream(
      id: row[0].toString(),
      ownerId: row[1].toString(),
      name: row[2] as String,
      seedBalance: Decimal.parse(seedBalanceRaw.toString()),
      seedDate: DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
      lossThreshold: Decimal.parse(row[5].toString()),
      displayOrder: row[6] as int,
      eventOrder: eventOrder,
      currencyScale: row[8] as int,
      version: row.length > 9 ? (row[9] as int? ?? 1) : 1,
      hasLoan: row.toColumnMap()['has_loan'] == true,
    );
  }
}

/// What deleting a stream does to the far side of its transfers.
enum TransferDeleteMode {
  /// Kept in the other stream as plain events (the default).
  keep,

  /// Deleted from the other streams too.
  delete;

  static TransferDeleteMode? parse(String? v) => switch (v) {
        null || '' || 'keep' => keep,
        'delete' => delete,
        _ => null,
      };
}
