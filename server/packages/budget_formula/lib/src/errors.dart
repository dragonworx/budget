/// Error codes; [FormulaError.codeName] is the snake_case API form.
enum FormulaErrorCode {
  empty,
  unexpectedCharacter,
  unexpectedToken,
  expectedOperand,
  missingOperator,
  unclosedParen,
  unmatchedParen,
  badNumber,
  numberTooLong,
  unknownVariable,
  reservedSyntax,
  tooLong,
  tooDeep,
  divisionByZero,
  overflow,
  cycle,
  outOfRange,
  notWhole,
  tooManyDecimals,
}

/// A problem with a span to underline ([start] == [end] at the end of the
/// text means "something is missing here"; draw it under the last
/// character).
class FormulaError {
  final FormulaErrorCode code;
  final String message;
  final int start;
  final int end;
  final String? hint;

  const FormulaError(this.code, this.message, this.start, this.end,
      {this.hint});

  String get codeName => code.name
      .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

  Map<String, Object?> toJson() => {
        'code': codeName,
        'message': message,
        'start': start,
        'end': end,
        if (hint != null) 'hint': hint,
      };

  @override
  bool operator ==(Object other) =>
      other is FormulaError &&
      other.code == code &&
      other.message == message &&
      other.start == start &&
      other.end == end &&
      other.hint == hint;

  @override
  int get hashCode => Object.hash(code, message, start, end, hint);

  @override
  String toString() =>
      'FormulaError($codeName [$start,$end) "$message"${hint == null ? '' : ' hint "$hint"'})';
}
