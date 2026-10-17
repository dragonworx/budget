import 'package:decimal/decimal.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';

class AccountRepo {
  AccountRepo(this._conn);

  final Session _conn;
  final _uuid = const Uuid();

  Future<List<Account>> listByProject(String projectId) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, project_id, name, currency, seed_balance, seed_date,
               loss_threshold, display_order, transaction_order, currency_scale
        FROM accounts
        WHERE project_id = @projectId
        ORDER BY display_order ASC, name ASC
      '''),
      parameters: {'projectId': projectId},
    );
    return rows.map(_fromRow).toList();
  }

  Future<Account?> get(String id) async {
    final rows = await _conn.execute(
      Sql.named('''
        SELECT id, project_id, name, currency, seed_balance, seed_date,
               loss_threshold, display_order, transaction_order, currency_scale
        FROM accounts WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Account> create({
    required String projectId,
    required String name,
    required String currency,
    required Decimal seedBalance,
    required DateTime seedDate,
    required Decimal lossThreshold,
    int displayOrder = 0,
    int currencyScale = Account.defaultCurrencyScale,
  }) async {
    final id = _uuid.v4();
    final rows = await _conn.execute(
      Sql.named('''
        INSERT INTO accounts (
          id, project_id, name, currency, seed_balance, seed_date,
          loss_threshold, display_order, currency_scale
        ) VALUES (
          @id, @projectId, @name, @currency, @seedBalance, @seedDate,
          @lossThreshold, @displayOrder, @currencyScale
        )
        RETURNING id, project_id, name, currency, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale
      '''),
      parameters: {
        'id': id,
        'projectId': projectId,
        'name': name,
        'currency': currency.toUpperCase(),
        'seedBalance': seedBalance.toString(),
        'seedDate': DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
        'lossThreshold': lossThreshold.toString(),
        'displayOrder': displayOrder,
        'currencyScale': currencyScale,
      },
    );
    return _fromRow(rows.first);
  }

  Future<Account?> update(
    String id, {
    String? name,
    String? currency,
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
        UPDATE accounts SET
          name = @name,
          currency = @currency,
          seed_balance = @seedBalance,
          seed_date = @seedDate,
          loss_threshold = @lossThreshold,
          display_order = @displayOrder,
          currency_scale = @currencyScale
        WHERE id = @id
        RETURNING id, project_id, name, currency, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale
      '''),
      parameters: {
        'id': id,
        'name': name ?? existing.name,
        'currency': (currency ?? existing.currency).toUpperCase(),
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

  /// Moves every transaction schedule of [accountId] by [days] calendar
  /// days (start date, until-date end, skipped dates) so the schedule keeps
  /// its position relative to the seed date. Run inside the same DB
  /// transaction as the seed-date update. Returns the number of
  /// transactions moved.
  Future<int> shiftSchedules(String accountId, int days) async {
    if (days == 0) return 0;
    // Transfers move as a pair: the peer row in the other account shifts
    // with its source so both sides keep the same dates.
    const scope = '''
      account_id = @id OR transfer_id IN (
        SELECT transfer_id FROM transactions
        WHERE account_id = @id AND transfer_id IS NOT NULL)''';
    final moved = await _conn.execute(
      Sql.named('''
        UPDATE transactions SET
          start_date = start_date + @d::int,
          end_date = CASE WHEN end_date IS NULL THEN NULL ELSE end_date + @d::int END
        WHERE $scope
        RETURNING account_id = @id
      '''),
      parameters: {'id': accountId, 'd': days},
    );
    // Skipped dates: delete + re-insert, so a uniform shift can't trip the
    // (transaction_id, date) primary key mid-update.
    final skipped = await _conn.execute(
      Sql.named('''
        DELETE FROM skipped_occurrences
        WHERE transaction_id IN (SELECT id FROM transactions WHERE $scope)
        RETURNING transaction_id::text, date
      '''),
      parameters: {'id': accountId},
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
    return moved.where((r) => r[0] == true).length;
  }

  Future<Account?> reorderTransactions(
      String id, List<String> transactionIds) async {
    final rows = await _conn.execute(
      Sql.named('''
        UPDATE accounts SET transaction_order = @transactionOrder
        WHERE id = @id
        RETURNING id, project_id, name, currency, seed_balance, seed_date,
                  loss_threshold, display_order, transaction_order, currency_scale
      '''),
      parameters: {
        'id': id,
        'transactionOrder': transactionIds,
      },
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<bool> delete(String id) async {
    await _conn.execute(
      Sql.named('''
        UPDATE transactions SET transfer_id = NULL
        WHERE account_id <> @a::uuid AND transfer_id IN (
          SELECT transfer_id FROM transactions
          WHERE account_id = @a::uuid AND transfer_id IS NOT NULL)
      '''),
      parameters: {'a': id},
    );
    final rows = await _conn.execute(
      Sql.named('DELETE FROM accounts WHERE id = @id RETURNING id'),
      parameters: {'id': id},
    );
    return rows.isNotEmpty;
  }

  Account _fromRow(ResultRow row) {
    final seedBalanceRaw = row[4];
    final transactionOrderRaw = row[8];
    final List<String> transactionOrder;
    if (transactionOrderRaw == null) {
      transactionOrder = const [];
    } else if (transactionOrderRaw is List) {
      transactionOrder = transactionOrderRaw.map((e) => e.toString()).toList();
    } else {
      transactionOrder = const [];
    }

    final seedDate = row[5] as DateTime;
    return Account(
      id: row[0].toString(),
      projectId: row[1].toString(),
      name: row[2] as String,
      currency: (row[3] as String).trim(),
      seedBalance: Decimal.parse(seedBalanceRaw.toString()),
      seedDate: DateTime.utc(seedDate.year, seedDate.month, seedDate.day),
      lossThreshold: Decimal.parse(row[6].toString()),
      displayOrder: row[7] as int,
      transactionOrder: transactionOrder,
      currencyScale: row[9] as int,
    );
  }
}
