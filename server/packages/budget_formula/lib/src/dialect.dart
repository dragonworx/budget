import 'package:rational/rational.dart';

/// A function a future dialect may enable (`round($x / 7)`).
class FormulaFunction {
  final int minArgs;
  final int maxArgs;
  final Rational Function(List<Rational> args) impl;
  const FormulaFunction(this.minArgs, this.maxArgs, this.impl);
}

/// Which reserved features are enabled. v1 enables none; a later version
/// turns one on, adds its handler and bumps `formulaGrammarVersion`.
class FormulaDialect {
  /// `5%` means 5 / 100.
  final bool percentLiterals;

  /// `2 ^ 3`, right-associative, whole exponents.
  final bool power;

  /// Functions by lower-case name.
  final Map<String, FormulaFunction> functions;

  /// Unit literals (`3 weeks`): reserved, no handler yet.
  final bool units;

  const FormulaDialect({
    this.percentLiterals = false,
    this.power = false,
    this.functions = const {},
    this.units = false,
  });

  static const v1 = FormulaDialect();
}
