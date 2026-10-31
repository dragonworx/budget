import 'package:postgres/postgres.dart' hide Pool;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../domain/enums.dart';
import '../domain/models.dart';
import '../engine/balance_engine.dart';
import '../engine/calendar_math.dart';
import '../engine/goal_solver.dart';
import '../engine/solver.dart' show SolverException;
import '../repo/stream_repo.dart';
import '../repo/event_repo.dart';
import 'balance.dart' show checkBalanceRange;
import 'loan_fields.dart' show planningNotSupported;
import 'json_helpers.dart';

double? _optDouble(Map<String, dynamic> body, String key) {
  final v = body[key];
  if (v == null || (v is String && v.trim().isEmpty)) return null;
  if (v is num) return v.toDouble();
  final d = double.tryParse(v.toString());
  if (d == null) throw FormatException('Invalid number: $key');
  return d;
}

GoalRequest parseGoalRequest(Map<String, dynamic> body) {
  DateTime? date(String k) =>
      optionalString(body, k) == null ? null : parseDate(body[k].toString());
  final unit = optionalString(body, 'unit');
  final mode = optionalString(body, 'mode');
  return GoalRequest(
    solveFor: GoalVar.parse(requireString(body, 'solveFor')),
    mode: mode == null ? GoalMode.onDate : GoalMode.parse(mode),
    unit: unit == null ? RecurrenceUnit.weeks : RecurrenceUnit.parse(unit),
    startDate: date('startDate'),
    endDate: date('endDate'),
    startBalance: _optDouble(body, 'startBalance'),
    targetBalance: _optDouble(body, 'targetBalance'),
    amount: _optDouble(body, 'amount'),
    interval: optionalInt(body, 'interval'),
    count: optionalInt(body, 'count'),
    oneOff: _optDouble(body, 'oneOff'),
    rate: _optDouble(body, 'rate'),
  );
}

/// Daily baseline (existing events only) for a goal request.
GoalBaseline goalBaseline({
  required BudgetStream stream,
  required List<BudgetEvent> events,
  required Map<String, Set<DateTime>> skipped,
  required GoalRequest request,
  required DateTime today,
  int horizonDays = 365 * 50,
}) {
  final t = CalendarMath.dateOnly(today);
  var from = CalendarMath.dateOnly(request.startDate ?? t);
  if (request.solveFor == GoalVar.startDate &&
      CalendarMath.compare(t, from) < 0) {
    from = t;
  }
  final to = request.solveFor == GoalVar.endDate || request.endDate == null
      ? from.add(Duration(days: horizonDays))
      : CalendarMath.dateOnly(request.endDate!);
  final end = CalendarMath.compare(to, from) < 0 ? from : to;
  final dayBefore = from.subtract(const Duration(days: 1));
  checkBalanceRange(dayBefore, end, seed: stream.seedDate);
  final series = BalanceEngine.compute(
    seedBalance: stream.seedBalance,
    seedDate: stream.seedDate,
    events: events,
    eventOrder: stream.eventOrder,
    from: dayBefore,
    to: end,
    skipped: skipped,
  );
  final byDay = {
    for (final p in series.points) p.date: p.closingBalance.toDouble(),
  };
  final seed = stream.seedBalance.toDouble();
  final opening = byDay[dayBefore] ?? seed;
  final n = CalendarMath.daysBetween(from, end) + 1;
  var last = opening;
  final closes = List<double>.generate(n, (i) {
    final d = from.add(Duration(days: i));
    last = byDay[d] ?? last;
    return last;
  });
  return GoalBaseline(from: from, opening: opening, closes: closes);
}

/// Registers `POST /<streamId>/goal` on [router].
void attachGoalRoutes(Router router, Session conn) {
  final streams = StreamRepo(conn);
  final events = EventRepo(conn);

  router.post('/<streamId>/goal', (Request request, String streamId) async {
    try {
      final stream = await streams.get(streamId);
      if (stream == null) return jsonError(404, 'stream not found');
      if (stream.hasLoan) return jsonError(409, planningNotSupported);
      final body = await readJsonObject(request);
      final goal = parseGoalRequest(body);
      final today = body['today'] == null
          ? DateTime.now().toUtc()
          : parseDate(body['today'].toString());
      final baseline = goalBaseline(
        stream: stream,
        events: await events.listByStream(streamId),
        skipped: await events.skipsForStream(streamId),
        request: goal,
        today: today,
      );
      final result = GoalSolver(
        baseline: baseline,
        threshold: stream.lossThreshold.toDouble(),
        today: today,
      ).solve(goal);
      return jsonOk(result.toJson());
    } on FormatException catch (e) {
      return jsonError(400, e.message);
    } on SolverException catch (e) {
      return jsonError(400, e.message);
    } on ArgumentError catch (e) {
      return jsonError(400, e.message.toString());
    }
  });
}
