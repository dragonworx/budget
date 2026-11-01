import 'evaluator.dart';
import 'lexer.dart';
import 'names.dart';
import 'token.dart';

/// Where a `$name` suggestion would go: replace `[replaceStart,
/// replaceEnd)` (from the `$` to the end of the name) with `$chosen`.
class CompletionContext {
  final int replaceStart;
  final int replaceEnd;

  /// What's typed between the `$` and the caret.
  final String prefix;
  const CompletionContext(this.replaceStart, this.replaceEnd, this.prefix);

  @override
  bool operator ==(Object other) =>
      other is CompletionContext &&
      other.replaceStart == replaceStart &&
      other.replaceEnd == replaceEnd &&
      other.prefix == prefix;
  @override
  int get hashCode => Object.hash(replaceStart, replaceEnd, prefix);
  @override
  String toString() => 'Completion[$replaceStart,$replaceEnd) "$prefix"';
}

/// The completion context at [caret], or null when the caret isn't right
/// after a `$` or within / at the end of a `$name`. A `$` followed by a
/// digit is a currency sign, not a variable.
CompletionContext? completionAt(String text, int caret) {
  if (caret < 1 || caret > text.length) return null;
  for (final t in tokenize(text)) {
    if (t.start >= caret) break;
    if (t.kind == TokenKind.variable && t.start < caret && caret <= t.end) {
      return CompletionContext(
          t.start, t.end, text.substring(t.start + 1, caret));
    }
  }
  return null;
}

/// [vars] matching [prefix] (case-insensitive): prefix matches first, then
/// substring matches, each in natural name order; at most [limit].
List<VariableValue> rankCompletions(String prefix, Iterable<VariableValue> vars,
    {int limit = 50}) {
  final p = prefix.toLowerCase();
  final starts = <VariableValue>[], contains = <VariableValue>[];
  for (final v in vars) {
    final l = v.name.toLowerCase();
    if (l.startsWith(p)) {
      starts.add(v);
    } else if (l.contains(p)) {
      contains.add(v);
    }
  }
  int by(VariableValue a, VariableValue b) => compareNames(a.name, b.name);
  starts.sort(by);
  contains.sort(by);
  return [...starts, ...contains].take(limit).toList();
}
