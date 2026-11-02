/// Formula grammar v1 (see /workspace/specs/variables-plan-review.md,
/// "Grammar reference"): `rent * 12 / 52`, `(1200 + 50) * 2`, `-x + 5`.
library;

export 'src/ast.dart';
export 'src/completion.dart';
export 'src/dialect.dart';
export 'src/errors.dart';
export 'src/evaluator.dart';
export 'src/field_spec.dart';
export 'src/field_specs.dart';
export 'src/graph.dart';
export 'src/highlight.dart';
export 'src/legacy.dart';
export 'src/lexer.dart';
export 'src/names.dart';
export 'src/parser.dart';
export 'src/printer.dart';
export 'src/resolve.dart';
export 'src/rewrite.dart';
export 'src/rounding.dart';
export 'src/token.dart';

/// Bumped whenever the dialect gains a feature. Additive: a text valid in
/// version N parses and evaluates identically in N+1, so rows store none.
const int formulaGrammarVersion = 1;
