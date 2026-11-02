import 'evaluator.dart';
import 'lexer.dart';
import 'token.dart';

/// Lower-case names of every variable reference in [text] (token-based, so it works
/// on text that doesn't parse).
Set<String> referencedNames(String text) => {
      for (final t in tokenize(text))
        if (t.kind == TokenKind.variable && t.name!.isNotEmpty)
          t.name!.toLowerCase(),
    };

/// [text] with every reference to [oldName] (case-insensitive, whole
/// token) replaced by [newName]. Every other character is kept: spacing, aliases, other
/// names' case. Works on broken formulas too.
String renameVariable(String text, String oldName, String newName) {
  final old = oldName.toLowerCase();
  final b = StringBuffer();
  for (final t in tokenize(text)) {
    if (t.kind == TokenKind.variable && t.name!.toLowerCase() == old) {
      b.write(newName);
    } else {
      b.write(t.lexeme);
    }
  }
  return b.toString();
}

/// The stored form: trimmed, operator aliases and NBSPs in ASCII, known
/// names in their canonical case (unknown names as typed).
String canonicalise(String text, VariableLookup vars) {
  final b = StringBuffer();
  for (final t in tokenize(text.trim())) {
    if (t.kind == TokenKind.variable && t.name!.isNotEmpty) {
      final v = vars.lookup(t.name!.toLowerCase());
      b.write(v?.name ?? t.name);
    } else {
      b.write(t.ascii);
    }
  }
  return b.toString();
}
