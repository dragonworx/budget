/// Variable dependency graphs: `deps[a]` = the lower-case names `a`'s
/// formula uses. Names that aren't keys are leaves (plain values or
/// unknown names reported elsewhere).
library;

/// Maximum chain length (a variable using a variable using ... : 16 deep).
const int maxVariableChain = 16;

class FormulaCycleException implements Exception {
  final List<String> cycle;
  FormulaCycleException(this.cycle);
  @override
  String toString() => 'Cycle: ${formatCycle(cycle)}';
}

/// `a → b → a`.
String formatCycle(List<String> cycle) => cycle.join(' → ');

/// A cycle as a path that starts and ends at the same name
/// (`['a', 'b', 'a']`, `['a', 'a']` for a self-reference), or null.
/// Deterministic: nodes and edges are visited in sorted order.
List<String>? findCycle(Map<String, Set<String>> deps) {
  const white = 0, grey = 1, black = 2;
  final colour = <String, int>{};
  final stack = <String>[];
  List<String>? visit(String n) {
    colour[n] = grey;
    stack.add(n);
    for (final m in [...?deps[n]]..sort()) {
      if (!deps.containsKey(m)) continue;
      final c = colour[m] ?? white;
      if (c == grey) return [...stack.sublist(stack.indexOf(m)), m];
      if (c == white) {
        final r = visit(m);
        if (r != null) return r;
      }
    }
    stack.removeLast();
    colour[n] = black;
    return null;
  }

  for (final n in [...deps.keys]..sort()) {
    if ((colour[n] ?? white) == white) {
      final r = visit(n);
      if (r != null) return r;
    }
  }
  return null;
}

/// Every key, dependencies first (Kahn; ties in name order). Throws
/// [FormulaCycleException] on a cycle.
List<String> topoOrder(Map<String, Set<String>> deps) {
  final cycle = findCycle(deps);
  if (cycle != null) throw FormulaCycleException(cycle);
  final remaining = <String, int>{
    for (final e in deps.entries)
      e.key: e.value.where(deps.containsKey).toSet().length,
  };
  final users = <String, List<String>>{};
  for (final e in deps.entries) {
    for (final d in e.value.where(deps.containsKey).toSet()) {
      (users[d] ??= []).add(e.key);
    }
  }
  final ready = [
    for (final e in remaining.entries)
      if (e.value == 0) e.key
  ]..sort();
  final out = <String>[];
  while (ready.isNotEmpty) {
    final n = ready.removeAt(0);
    out.add(n);
    var added = false;
    for (final u in users[n] ?? const <String>[]) {
      remaining[u] = remaining[u]! - 1;
      if (remaining[u] == 0) {
        ready.add(u);
        added = true;
      }
    }
    if (added) ready.sort();
  }
  return out;
}

/// Each key's chain depth: 1 for a variable that uses no other variable,
/// else 1 + the deepest variable it uses. Throws on a cycle.
Map<String, int> chainDepths(Map<String, Set<String>> deps) {
  final out = <String, int>{};
  for (final n in topoOrder(deps)) {
    var d = 1;
    for (final m in deps[n]!) {
      final dm = out[m];
      if (dm != null && dm + 1 > d) d = dm + 1;
    }
    out[n] = d;
  }
  return out;
}

/// The first (name-ordered) variable whose chain is deeper than [max], or
/// null.
String? tooDeepVariable(Map<String, Set<String>> deps,
    {int max = maxVariableChain}) {
  final d = chainDepths(deps);
  final over = [
    for (final e in d.entries)
      if (e.value > max) e.key
  ]..sort();
  return over.isEmpty ? null : over.first;
}
