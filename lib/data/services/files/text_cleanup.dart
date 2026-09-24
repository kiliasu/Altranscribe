class CleanupOptions {
  const CleanupOptions({
    this.names = false,
    this.terms = false,
    this.corrections = false,
    this.spellings = const [],
  });
  final bool names;
  final bool terms;
  final bool corrections;
  final List<String> spellings;
  bool get enabled => names || terms || corrections;
  bool allows(String category) => switch (category) {
    'name' => names,
    'term' => terms,
    'correction' => corrections,
    _ => false,
  };
  Map<String, Object?> toJson() => {
    'names': names,
    'terms': terms,
    'corrections': corrections,
    'spellings': spellings,
  };
}

class CleanupEdit {
  const CleanupEdit(this.category, this.from, this.to, this.evidence);
  final String category;
  final String from;
  final String to;
  final String evidence;
  Map<String, Object?> toJson() => {
    'category': category,
    'from': from,
    'to': to,
    'evidence': evidence,
  };
  factory CleanupEdit.fromJson(Map<String, dynamic> json) => CleanupEdit(
    json['category'] as String,
    json['from'] as String,
    json['to'] as String,
    json['evidence'] as String,
  );

  // Avoid replacing an English name inside another name or technical identifier.
  static RegExp pattern(String word) => RegExp(
    '${RegExp(r"^[A-Za-z0-9_]").hasMatch(word) ? r"(?<![A-Za-z0-9_])" : ""}'
    '${RegExp.escape(word)}'
    '${RegExp(r"[A-Za-z0-9_]$").hasMatch(word) ? r"(?![A-Za-z0-9_])" : ""}',
  );
}

class CleanupResult {
  const CleanupResult(this.texts, this.edits);
  final List<String> texts;
  final List<List<CleanupEdit>> edits;

  /// A model's self-rating alone is insufficient: a preferred spelling or at
  /// least two literal occurrences elsewhere in this document are also needed.
  static CleanupResult validate(
    List<String> originals,
    CleanupOptions options,
    List<dynamic> proposals,
  ) {
    final accepted = <String, CleanupEdit>{};
    final conflicts = <String>{};
    for (final value in proposals) {
      if (value is! Map || value['confidence'] != 'high') continue;
      final category = value['category'];
      final from = value['from'];
      final to = value['to'];
      if (category is! String ||
          !options.allows(category) ||
          from is! String ||
          to is! String ||
          from == to ||
          from.trim() != from ||
          to.trim() != to ||
          from.isEmpty ||
          to.isEmpty ||
          from.runes.length > 40 ||
          to.runes.length > 40 ||
          from.contains('\n') ||
          to.contains('\n') ||
          from.split(RegExp(r'\s+')).length > 5 ||
          to.split(RegExp(r'\s+')).length > 5) {
        continue;
      }
      // Numbers are facts, not spelling corrections.
      String numbers(String text) =>
          RegExp(r'\d+').allMatches(text).map((m) => m[0]).join('|');
      if (numbers(from) != numbers(to)) continue;
      final sourcePattern = CleanupEdit.pattern(from);
      if (!originals.any(sourcePattern.hasMatch)) continue;
      final targetPattern = CleanupEdit.pattern(to);
      final count = originals.fold<int>(
        0,
        (sum, text) => sum + targetPattern.allMatches(text).length,
      );
      final preferred = options.spellings.contains(to);
      if (!preferred && count < 2) continue;
      if (accepted[from] != null && accepted[from]!.to != to) {
        conflicts.add(from);
      }
      accepted[from] = CleanupEdit(
        category,
        from,
        to,
        preferred ? 'glossary' : 'repeated',
      );
    }
    // Reject conflicts, cycles and chains; never cascade edits into new text.
    final edits = accepted.values
        .where(
          (edit) =>
              !conflicts.contains(edit.from) && !accepted.containsKey(edit.to),
        )
        .toList();
    final revised = <String>[];
    final changes = <List<CleanupEdit>>[];
    for (final original in originals) {
      final matches = <(int, int, CleanupEdit)>[];
      for (final edit in edits) {
        for (final match in CleanupEdit.pattern(
          edit.from,
        ).allMatches(original)) {
          matches.add((match.start, match.end, edit));
        }
      }
      matches.sort((a, b) => a.$1.compareTo(b.$1));
      final valid = matches
          .where(
            (a) => !matches.any((b) => a != b && a.$1 < b.$2 && b.$1 < a.$2),
          )
          .toList();
      var result = original;
      for (final match in valid.reversed) {
        result = result.replaceRange(match.$1, match.$2, match.$3.to);
      }
      revised.add(result);
      changes.add(valid.map((match) => match.$3).toSet().toList());
    }
    return CleanupResult(revised, changes);
  }
}
