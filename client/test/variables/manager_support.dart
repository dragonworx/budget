// Fakes for the variables manager tests (spec 012): an in-memory
// VariableRepository and a StreamRepository that only answers get().
import 'dart:convert';

import 'package:budget_client/data/api_client.dart';
import 'package:budget_client/data/models.dart';
import 'package:budget_client/data/repositories.dart';
import 'package:budget_client/features/variables/variables_manager.dart';
import 'package:budget_client/state/providers.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../formula/plain_golden_support.dart' show testTheme;

Variable vr(
  String id,
  String name,
  String expr, {
  String unit = 'money',
  String? value,
  int uses = 0,
  String? description,
  Map<String, dynamic>? problem,
  int? decimals,
}) => Variable(
  id: id,
  name: name,
  unit: unit,
  expr: expr,
  value: Decimal.parse(value ?? expr),
  usageCount: uses,
  description: description,
  problem: problem,
  displayDecimals: decimals,
  version: 1,
);

ApiException apiError(int status, String message, Map<String, dynamic> d) =>
    ApiException(
      message,
      statusCode: status,
      body: jsonEncode({'error': message, 'details': d}),
    );

class FakeVars extends VariableRepository {
  FakeVars(List<Variable> initial) : super(ApiClient(baseUrl: 'http://x')) {
    for (final v in initial) {
      store[v.id] = v;
    }
  }

  final store = <String, Variable>{};

  /// Writes and lookups (list reads go to [reads]).
  final calls = <String>[];
  final reads = <String>[];
  Object? failNext;
  Map<String, dynamic> attentionJson = const {'items': [], 'count': 0};
  final usagesJson = <String, Map<String, dynamic>>{};
  Map<String, dynamic> previewJson = const {'changes': [], 'invalid': 0};
  int _n = 0;

  void _fail() {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }

  List<Variable> get _all => store.values.toList();

  @override
  Future<List<Variable>> list(String streamId) async {
    reads.add('list $streamId');
    return _all;
  }

  @override
  Future<List<Variable>> listMine() async {
    reads.add('mine');
    return _all;
  }

  @override
  Future<Variable> create({
    String? streamId,
    required String name,
    required String expr,
    String unit = 'number',
    String? description,
    int? displayDecimals,
  }) async {
    calls.add('create $name=$expr $unit');
    _fail();
    final id = 'n${++_n}';
    final v = Variable(
      id: id,
      name: name,
      unit: unit,
      expr: expr,
      value: Decimal.tryParse(expr) ?? Decimal.fromInt(42),
      description: description,
      displayDecimals: displayDecimals,
      version: 1,
    );
    store[id] = v;
    return v;
  }

  @override
  Future<Variable> update(
    String id, {
    String? streamId,
    String? name,
    String? expr,
    String? unit,
    String? description,
    int? displayDecimals,
    int? version,
  }) async {
    calls.add(
      'update $id${name == null ? '' : ' name=$name'}'
      '${expr == null ? '' : ' expr=$expr'}'
      '${unit == null ? '' : ' unit=$unit'}'
      '${description == null ? '' : ' description=$description'}'
      '${displayDecimals == null ? '' : ' decimals=$displayDecimals'}',
    );
    _fail();
    final o = store[id]!;
    final v = Variable(
      id: id,
      name: name ?? o.name,
      unit: unit ?? o.unit,
      expr: expr ?? o.expr,
      value: expr == null ? o.value : Decimal.tryParse(expr) ?? o.value,
      description: description == null
          ? o.description
          : (description.isEmpty ? null : description),
      displayDecimals: displayDecimals ?? o.displayDecimals,
      usageCount: o.usageCount,
      version: (o.version ?? 0) + 1,
    );
    store[id] = v;
    return v;
  }

  @override
  Future<void> delete(String id, {String? streamId}) async {
    calls.add('delete $id');
    _fail();
    store.remove(id);
  }

  @override
  Future<Map<String, dynamic>> usages(String id, {String? streamId}) async {
    calls.add('usages $id');
    return usagesJson[id] ?? const {'usages': [], 'hidden': 0};
  }

  @override
  Future<Map<String, dynamic>> preview(
    String id,
    String expr, {
    String? streamId,
  }) async {
    calls.add('preview $id $expr');
    return previewJson;
  }

  @override
  Future<Map<String, dynamic>> attention({String? streamId}) async =>
      attentionJson;
}

class FakeStreams extends StreamRepository {
  FakeStreams(this.role) : super(ApiClient(baseUrl: 'http://x'));
  Role role;

  @override
  Future<BudgetStream> get(String id) async => BudgetStream(
    id: id,
    ownerId: 'u',
    name: 'Everyday',
    seedBalance: Decimal.fromInt(1000),
    seedDate: DateTime(2026, 1, 1),
    lossThreshold: Decimal.zero,
    currencyScale: 100,
    role: role,
  );
}

/// The base set: rent (used 2), rate (percent), weeks (number, formula).
List<Variable> baseVars() => [
  vr('v1', 'rent', '1200', uses: 2, description: 'Weekly rent'),
  vr('v2', 'rate', '5.5', unit: 'percent'),
  vr('v3', 'weeks', r'$months * 4', unit: 'number', value: '48'),
  vr('v4', 'months', '12', unit: 'number', uses: 1),
];

class ManagerHarness {
  ManagerHarness(this.vars, this.streams);
  final FakeVars vars;
  final FakeStreams streams;
  String? result = 'unset';
}

/// A page with an "Open" button that opens the manager.
Future<ManagerHarness> pumpManager(
  WidgetTester tester, {
  List<Variable>? vars,
  String? streamId,
  Role role = Role.owner,
  double width = 800,
  double height = 900,
  TargetPlatform? platform,
  String? createName,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ManagerHarness(FakeVars(vars ?? baseVars()), FakeStreams(role));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        variableRepositoryProvider.overrideWithValue(h.vars),
        streamRepositoryProvider.overrideWithValue(h.streams),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: platform == null
            ? testTheme
            : testTheme.copyWith(platform: platform),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () async => h.result = await showVariablesManager(
                  context,
                  streamId: streamId,
                  createName: createName,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
  return h;
}

Finder k(String key) => find.byKey(ValueKey(key));

String textOf(WidgetTester tester, String key) =>
    (tester.widget(k(key)) as Text).data!;

/// Enters [text] in the TextField / FormulaField under [key].
Future<void> enter(WidgetTester tester, String key, String text) async {
  await tester.enterText(
    find.descendant(of: k(key), matching: find.byType(EditableText)),
    text,
  );
  await tester.pump();
}
