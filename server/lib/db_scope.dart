import 'dart:async';

import 'package:postgres/postgres.dart';

const _txKey = #budgetRequestTx;

/// A DB handle that routes every statement to the current request's
/// transaction when one is open (see [runInRequestTx]), else to [base]
/// (a pool in the server, a connection in tests).
///
/// The API's repos and handlers are built once with this handle, so the
/// authz middleware can run a whole mutating request — handler writes plus
/// its audit_log row and NOTIFY — in ONE transaction without the handlers
/// knowing.
class ScopedDb implements Session, SessionExecutor {
  ScopedDb(this.base) : _exec = base as SessionExecutor;

  final Session base;
  final SessionExecutor _exec;

  TxSession? get currentTx => Zone.current[_txKey] as TxSession?;
  Session get _s => currentTx ?? base;

  @override
  bool get isOpen => base.isOpen;

  @override
  Future<void> get closed => base.closed;

  @override
  Future<Statement> prepare(Object query) => _s.prepare(query);

  @override
  Future<Result> execute(Object query,
          {Object? parameters,
          bool ignoreRows = false,
          QueryMode? queryMode,
          Duration? timeout}) =>
      _s.execute(query,
          parameters: parameters,
          ignoreRows: ignoreRows,
          queryMode: queryMode,
          timeout: timeout);

  @override
  Future<R> run<R>(Future<R> Function(Session session) fn,
      {SessionSettings? settings}) {
    final tx = currentTx;
    if (tx != null) return fn(tx);
    return _exec.run(fn, settings: settings);
  }

  /// Nested transactions join the request transaction (all-or-nothing).
  @override
  Future<R> runTx<R>(Future<R> Function(TxSession session) fn,
      {TransactionSettings? settings}) {
    final tx = currentTx;
    if (tx != null) return fn(tx);
    return _exec.runTx(fn, settings: settings);
  }

  @override
  Future<void> close({bool force = false}) => _exec.close(force: force);

  /// Runs [fn] inside one transaction; all statements on this handle made
  /// within [fn] (and its async continuations) use it. Throwing rolls back.
  Future<R> runInRequestTx<R>(Future<R> Function() fn) {
    if (currentTx != null) return fn();
    return _exec.runTx((tx) => runZoned(fn, zoneValues: {_txKey: tx}));
  }
}

/// Thrown inside [ScopedDb.runInRequestTx] to roll back while still
/// returning [value] (e.g. a non-2xx response).
class RollbackWith<T> implements Exception {
  RollbackWith(this.value);
  final T value;
}
