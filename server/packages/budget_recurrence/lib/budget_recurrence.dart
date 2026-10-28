/// The structured frequency rule shared by the server and the client.
///
/// One canonical rule per event: [FreqRule] + interval N + an optional sorted
/// list of days. [fireDates] answers "which days fire in [from, to]", and
/// [describeFrequency] builds the human phrase, identically on both sides.
library;

export 'src/frequency.dart';
export 'src/engine.dart';
export 'src/phrase.dart';
