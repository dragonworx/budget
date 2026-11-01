/// Variable names: `[A-Za-z_][A-Za-z0-9_]{0,39}`, unique case-insensitively.
final RegExp variableNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,39}$');

const int maxVariableNameLength = 40;

/// Why [name] can't be a variable's name among [existingNames] (null when
/// it can). [self] is the variable's current name when renaming, so
/// keeping (or re-casing) its own name is fine. A typed leading `$` is
/// ignored.
String? variableNameProblem(String name, Iterable<String> existingNames,
    {String? self}) {
  var n = name.trim();
  if (n.startsWith(r'$')) n = n.substring(1);
  if (n.isEmpty) return 'Enter a name';
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n)) {
    return 'Use letters, digits and _; start with a letter or _';
  }
  if (n.length > maxVariableNameLength) {
    return 'At most $maxVariableNameLength characters';
  }
  final lower = n.toLowerCase();
  final selfLower = self?.toLowerCase();
  for (final e in existingNames) {
    final el = e.toLowerCase();
    if (el == lower && el != selfLower) {
      return 'A variable named "\$$e" already exists';
    }
  }
  return null;
}

/// Natural, case-insensitive name order ("rent2" < "rent10"): the same
/// rule as the client's `compareCategoryNames` (client/lib/data/models.dart).
int compareNames(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var i = 0, j = 0;
  bool digit(int c) => c >= 0x30 && c <= 0x39;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i), cy = y.codeUnitAt(j);
    if (digit(cx) && digit(cy)) {
      var ei = i, ej = j;
      while (ei < x.length && digit(x.codeUnitAt(ei))) {
        ei++;
      }
      while (ej < y.length && digit(y.codeUnitAt(ej))) {
        ej++;
      }
      final nx = x.substring(i, ei).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final ny = y.substring(j, ej).replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (nx.length != ny.length) return nx.length - ny.length;
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      i = ei;
      j = ej;
      continue;
    }
    if (cx != cy) return cx - cy;
    i++;
    j++;
  }
  final rest = (x.length - i) - (y.length - j);
  if (rest != 0) return rest;
  return a.compareTo(b);
}

/// Case-insensitive Levenshtein distance.
int editDistance(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  var prev = List<int>.generate(y.length + 1, (i) => i);
  for (var i = 1; i <= x.length; i++) {
    final cur = List<int>.filled(y.length + 1, 0)..[0] = i;
    for (var j = 1; j <= y.length; j++) {
      final cost = x.codeUnitAt(i - 1) == y.codeUnitAt(j - 1) ? 0 : 1;
      final a1 = prev[j] + 1, b1 = cur[j - 1] + 1, c1 = prev[j - 1] + cost;
      cur[j] = a1 < b1 ? (a1 < c1 ? a1 : c1) : (b1 < c1 ? b1 : c1);
    }
    prev = cur;
  }
  return prev[y.length];
}

/// The closest of [names] to [typed] within [maxDistance] edits (ties: the
/// first in [compareNames] order); null when none is that close.
String? closestName(String typed, Iterable<String> names,
    {int maxDistance = 2}) {
  String? best;
  var bestD = maxDistance + 1;
  final sorted = [...names]..sort(compareNames);
  for (final n in sorted) {
    final d = editDistance(typed, n);
    if (d < bestD) {
      best = n;
      bestD = d;
    }
  }
  return best;
}
