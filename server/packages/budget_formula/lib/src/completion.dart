import 'evaluator.dart';
import 'lexer.dart';
import 'names.dart';
import 'token.dart';

/// Where a variable suggestion would go: replace `[replaceStart,
/// replaceEnd)` (the whole name being typed) with the chosen name.
class CompletionContext {
  final int replaceStart;
  final int replaceEnd;

  /// What's typed of the name before the caret.
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

/// The completion context at [caret], or null when the caret isn't within
/// or at the end of a name (a word starting with a letter). A word glued
/// to a number (`1e3`, `12months`) isn't a name being typed, so digits
/// never open suggestions.
CompletionContext? completionAt(String text, int caret) {
  if (caret < 1 || caret > text.length) return null;
  FormulaToken? prev;
  for (final t in tokenize(text)) {
    if (t.start >= caret) break;
    if (_isWord(t) && t.start < caret && caret <= t.end) {
      if (prev != null &&
          prev.kind == TokenKind.number &&
          prev.end == t.start) {
        return null;
      }
      return CompletionContext(t.start, t.end, text.substring(t.start, caret));
    }
    prev = t;
  }
  return null;
}

bool _isWord(FormulaToken t) =>
    t.kind == TokenKind.variable ||
    (t.kind == TokenKind.identifier &&
        t.name == null &&
        !t.lexeme.startsWith('_'));

/// The text to insert for [name] at `[start, end)` of [text]: a space is
/// added where the name would otherwise run into a neighbouring name,
/// number or bracket (`2` + `rent` → `2 rent`, not `2rent`).
String insertionFor(String text, int start, int end, String name) {
  bool glues(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x2E;
  final before = start > 0 &&
      (glues(text.codeUnitAt(start - 1)) || text.codeUnitAt(start - 1) == 0x29);
  final after = end < text.length &&
      (glues(text.codeUnitAt(end)) || text.codeUnitAt(end) == 0x28);
  return '${before ? ' ' : ''}$name${after ? ' ' : ''}';
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
