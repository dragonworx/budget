// Whose variables a formula field resolves against (spec 011, D1/D10).
import 'package:budget_formula/budget_formula.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';

/// The variables one field can use. Shared viewers and editors see the
/// stream owner's whole set for now (011).
class VariableScope extends VariableLookup {
  VariableScope({
    this.streamId,
    this.variables = const [],
    this.canManage = false,
    this.loading = false,
    this.descriptions = const {},
    this.displayDecimals = const {},
  }) : _byLower = {for (final v in variables) v.name.toLowerCase(): v};

  /// From the API's [Variable]s.
  factory VariableScope.fromVariables(
    List<Variable> list, {
    String? streamId,
    bool canManage = false,
    bool loading = false,
  }) {
    final values = <VariableValue>[];
    final desc = <String, String>{};
    final decimals = <String, int>{};
    for (final v in list) {
      values.add(VariableValue(v.name, v.value, _unit(v.unit)));
      final l = v.name.toLowerCase();
      final d = v.description;
      if (d != null && d.trim().isNotEmpty) desc[l] = d.trim();
      if (v.displayDecimals != null) decimals[l] = v.displayDecimals!;
    }
    return VariableScope(
      streamId: streamId,
      variables: values,
      canManage: canManage,
      loading: loading,
      descriptions: desc,
      displayDecimals: decimals,
    );
  }

  static final VariableScope empty = VariableScope();

  /// The resolving stream; null = the caller's own set.
  final String? streamId;
  final List<VariableValue> variables;

  /// Owner: may offer "Create $x…" / "Manage variables…" (from 012).
  final bool canManage;
  final bool loading;

  /// By lower-case name.
  final Map<String, String> descriptions;
  final Map<String, int> displayDecimals;
  final Map<String, VariableValue> _byLower;

  @override
  VariableValue? lookup(String lowerName) => _byLower[lowerName];

  @override
  Iterable<VariableValue> get values => variables;

  bool isKnown(String lowerName) => _byLower.containsKey(lowerName);

  static VariableUnit _unit(String u) => switch (u) {
    'money' => VariableUnit.money,
    'percent' => VariableUnit.percent,
    _ => VariableUnit.number,
  };
}

/// The stream whose variables resolve an event's amount: the row's stream,
/// or for a transfer the debit side (D10): the row's stream when it pays
/// out, else the stream it is paid from ([transferToStreamId] is the peer).
String debitSideStreamId({
  required String rowStreamId,
  bool isTransfer = false,
  bool moneyOut = true,
  String? transferToStreamId,
}) {
  if (!isTransfer || moneyOut || transferToStreamId == null) {
    return rowStreamId;
  }
  return transferToStreamId;
}

/// The scope for a field in [streamId] (null = my own variables); watches
/// the provider so live `variable` events re-resolve open fields.
VariableScope scopeFor(WidgetRef ref, {String? streamId}) {
  final async = streamId == null
      ? ref.watch(myVariablesProvider)
      : ref.watch(variablesProvider(streamId));
  return VariableScope.fromVariables(
    async.valueOrNull ?? const [],
    streamId: streamId,
    // The manager arrives in 012; until then there is nothing to offer.
    canManage: false,
    loading: async.isLoading && !async.hasValue,
  );
}
