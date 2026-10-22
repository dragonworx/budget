import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart' hide Pool;
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

class PoolRepo {
  PoolRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  /// Pools [userId] owns or has been shared, with their role, owner and
  /// whether they are shared with them. Mine first (display order, name),
  /// then shared ones by name.
  Future<List<Map<String, Object?>>> listAccessible(String userId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT a.id, a.owner_id, a.name, a.seed_balance, a.seed_date,
               a.loss_threshold, a.display_order, a.transaction_order,
               a.currency_scale, a.version,
               CASE WHEN a.owner_id = @u::uuid THEN 'owner' ELSE s.role::text END,
               u.email, u.name, u.picture_url
        FROM pools a
        JOIN users u ON u.id = a.owner_id
        LEFT JOIN pool_shares s
          ON s.pool_id = a.id AND s.user_id = @u::uuid
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

  /// The pool [userId] opened last (may no longer be accessible).
  Future<String?> lastOpened(String userId) async {
    final r = await _conn.execute(
      Sql.named('SELECT last_pool_id::text FROM users WHERE id = @u::uuid'),
      parameters: {'u': userId},
    );
    return r.isEmpty ? null : r.first[0] as String?;
  }

  Future<void> markOpened(String userId, String poolId) async {
    await _conn.execute(
      Sql.named('UPDATE users SET last_pool_id = @a::uuid '
          'WHERE id = @u::uuid AND last_pool_id IS DISTINCT FROM @a::uuid'),
      parameters: {'u': userId, 'a': poolId},
    );
  }

  Future<Pool?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, owner_id, name, seed_balance, seed_date,
               loss_threshold, display_order, transaction_order, currency_scale, version
        FROM pools WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Pool> create({
    required String ownerId,
    required String name,
    required Decimal seedBalance,
    required DateTime seedDate,
    required Decimal lossThreshold,
    int displayOrder = 0,
    int currencyScale = Pool.defaultCurrencyScale,
  }) async {
    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO pools (
          id, owner_id, name, seed_balance, seed_date,
          loss_threshold, display_order, currency_scale, created_by
        ) VALUES (
          @id, @ownerId::uuid, @name, @seedBalance, @seedDate,
          @lossThreshold, @displayOrder, @currencyScale, @ownerId::uuid
        )
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale, version
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

  Future<Pool?> update(
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
        UPDATE pools SET
          name = @name,
          seed_balance = @seedBalance,
          seed_date = @seedDate,
          loss_threshold = @lossThreshold,
          display_order = @displayOrder,
          currency_scale = @currencyScale
        WHERE id = @id
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale, version
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

  /// Moves every transaction schedule of [poolId] by [days] calendar
  /// days (start date, until-date end, skipped dates) so the schedule keeps
  /// its position relative to the seed date. Run inside the same DB
  /// transaction as the seed-date update. Returns the number of
  /// transactions moved.
  Future<int> shiftSchedules(String poolId, int days) async {
    if (days == 0) return 0;
    // Transfers move as a pair: the peer row in the other pool shifts
    // with its source so both sides keep the same dates.
    const scope = '''
      pool_id = @id OR transfer_id IN (
        SELECT transfer_id FROM transactions
        WHERE pool_id = @id AND transfer_id IS NOT NULL)''';
    final moved = await _conn.execute(
      Sql.named('''
        UPDATE transactions SET
          start_date = start_date + @d::int,
          end_date = CASE WHEN end_date IS NULL THEN NULL ELSE end_date + @d::int END
        WHERE $scope
        RETURNING pool_id = @id
      '''),
      parameters: {'id': poolId, 'd': days},
    );
    // Skipped dates: delete + re-insert, so a uniform shift can't trip the
    // (transaction_id, date) primary key mid-update.
    final skipped = await _conn.execute(
      Sql.named('''
        DELETE FROM skipped_occurrences
        WHERE transaction_id IN (SELECT id FROM transactions WHERE $scope)
        RETURNING transaction_id::text, date
      '''),
      parameters: {'id': poolId},
    );
    for (final row in skipped) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO skipped_occurrences (transaction_id, date)
          VALUES (@t::uuid, @date::date + @d::int)
        '''),
        parameters: {'t': row[0], 'date': row[1], 'd': days},
      );
    }
    // Once-off overrides move with their occurrences, the same way.
    final overrides = await _conn.execute(
      Sql.named('''
        DELETE FROM occurrence_overrides
        WHERE transaction_id IN (SELECT id FROM transactions WHERE $scope)
        RETURNING transaction_id::text, date, amount::text, direction
      '''),
      parameters: {'id': poolId},
    );
    for (final row in overrides) {
      await _conn.execute(
        Sql.named('''
          INSERT INTO occurrence_overrides (transaction_id, date, amount, direction)
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

  Future<Pool?> reorderTransactions(
      String id, List<String> transactionIds) async {
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE pools SET transaction_order = COALESCE((
          -- Only this pool's own transactions, first mention wins.
          SELECT array_agg(x.id ORDER BY x.ord) FROM (
            SELECT DISTINCT ON (t.id) t.id, u.ord
            FROM unnest(@transactionOrder::text[]) WITH ORDINALITY u(v, ord)
            JOIN transactions t
              ON t.id::text = lower(u.v) AND t.pool_id = pools.id
            ORDER BY t.id, u.ord) x), '{}')
        WHERE id = @id
        RETURNING id, owner_id, name, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale, version
      '''),
      parameters: {
        'id': id,
        'transactionOrder': transactionIds,
      },
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Transfers between [poolId] and other pools: one row per peer (the
  /// surviving side), with its pool. Read before a delete.
  Future<List<({String peerId, String peerPoolId})>> transferPeers(
      String poolId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT p.id::text, p.pool_id::text FROM transactions p
        JOIN transactions t ON t.transfer_id = p.transfer_id AND t.id <> p.id
        WHERE t.pool_id = @a::uuid AND t.transfer_id IS NOT NULL
          AND p.pool_id <> @a::uuid
        ORDER BY p.pool_id, p.id
      '''),
      parameters: {'a': poolId},
    );
    return [
      for (final r in rows) (peerId: r[0] as String, peerPoolId: r[1] as String)
    ];
  }

  /// Deletes the pool and its own transactions (cascade). Its transfers'
  /// far sides in other pools never dangle: [transfers] keep turns each
  /// into a plain transaction of its pool (same name, direction, amount,
  /// schedule, skips, overrides, enabled: that pool's balance is
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
            UPDATE transactions
            SET transfer_id = NULL, version = version + 1, updated_at = now()
            WHERE id = ANY(@ids::uuid[]) RETURNING id::text
          '''),
          parameters: {'ids': ids},
        );
        converted.addAll(rows.map((r) => r[0] as String));
      } else {
        await _conn.execute(
          Sql.named('''
            UPDATE pools p SET transaction_order = COALESCE((
              SELECT array_agg(x ORDER BY o) FROM unnest(p.transaction_order)
                WITH ORDINALITY AS u(x, o)
              WHERE NOT (x = ANY(@ids::uuid[]))), '{}')
            WHERE p.id IN (SELECT pool_id FROM transactions
                           WHERE id = ANY(@ids::uuid[]))
          '''),
          parameters: {'ids': ids},
        );
        final rows = await _conn.execute(
          Sql.named('DELETE FROM transactions WHERE id = ANY(@ids::uuid[]) '
              'RETURNING id::text'),
          parameters: {'ids': ids},
        );
        removed.addAll(rows.map((r) => r[0] as String));
      }
    }
    final rows = await _conn.execute(
      Sql.named('DELETE FROM pools WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return (deleted: rows.isNotEmpty, converted: converted, removed: removed);
  }

  Pool _fromRow(ResultRow row) {
    final seedBalanceRaw = row[3];
    final transactionOrderRaw = row[7];
    final List<String> transactionOrder;
    if (transactionOrderRaw == null) {
      transactionOrder = const [];
    } else if (transactionOrderRaw is List) {
      transactionOrder = transactionOrderRaw.map((e) => e.toString()).toList();
    } else {
      transactionOrder = const [];
    }

    final seedDate = row[4] as DateTime;
    return Pool(
      id: row[0].toString(),
      ownerId: row[1].toString(),
      name: row[2] as String,
      seedBalance: Decimal.parse(seedBalanceRaw.toString()),
      seedDate: DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
      lossThreshold: Decimal.parse(row[5].toString()),
      displayOrder: row[6] as int,
      transactionOrder: transactionOrder,
      currencyScale: row[8] as int,
      version: row.length > 9 ? (row[9] as int? ?? 1) : 1,
    );
  }
}

/// What deleting a pool does to the far side of its transfers.
enum TransferDeleteMode {
  /// Kept in the other pool as plain transactions (the default).
  keep,

  /// Deleted from the other pools too.
  delete;

  static TransferDeleteMode? parse(String? v) => switch (v) {
        null || '' || 'keep' => keep,
        'delete' => delete,
        _ => null,
      };
}
