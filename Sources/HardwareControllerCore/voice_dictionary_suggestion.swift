import Foundation

/// One Dictionary entry inferred from a user's explicit History correction.
public enum VoiceDictionarySuggestion: Hashable, Sendable {
  /// A recognition hint for a name or term the recognizer missed.
  case vocabulary(String)
  /// A literal post-recognition replacement for a multiword mishearing.
  case replacement(spokenForm: String, replacement: String)
}

/// Infers Dictionary suggestions from one correction without guessing at
/// rewrites.
///
/// The rules follow what local dictation apps converged on: a short curated
/// list, suggested only from explicit edits, and always confirmed by the user.
/// Real-word substitutions are never turned into blind replacements, because a
/// single misheard word such as "capuchin" is also a legitimate word elsewhere.
public enum VoiceDictionarySuggester {
  /// Edits touching more than this many places are treated as rewrites.
  static let maximumEditedSpans = 3
  /// A span longer than this is a rewrite, not a misheard term.
  static let maximumSpanWords = 4
  /// Suggestions are shown together, so the list stays short.
  static let maximumSuggestions = 3

  public static func suggestions(
    original: String,
    corrected: String,
    dictionary: PersonalDictionary
  ) -> [VoiceDictionarySuggestion] {
    let source = words(in: original)
    let target = words(in: corrected)
    guard !source.isEmpty, !target.isEmpty else {
      return []
    }
    let spans = editedSpans(source: source, target: target)
    let editedSourceWords = spans.reduce(0) { $0 + $1.source.count }
    guard
      !spans.isEmpty,
      spans.count <= maximumEditedSpans,
      editedSourceWords <= max(2, source.count * 2 / 5)
    else {
      return []
    }
    var knownVocabulary = Set(dictionary.vocabulary.map { $0.lowercased() })
    var knownSpokenForms = Set(
      dictionary.replacements.map { $0.spokenForm.lowercased() }
    )
    var suggestions: [VoiceDictionarySuggestion] = []
    for span in spans where isTermSubstitution(span) {
      let term = span.target.map(\.text).joined(separator: " ")
      if knownVocabulary.insert(term.lowercased()).inserted {
        suggestions.append(.vocabulary(term))
      }
      let spokenForm = span.source.map(\.key).joined(separator: " ")
      if span.source.count >= 2, knownSpokenForms.insert(spokenForm).inserted {
        suggestions.append(.replacement(spokenForm: spokenForm, replacement: term))
      }
    }
    return Array(suggestions.prefix(maximumSuggestions))
  }

  /// Returns the Dictionary with the suggestion added, or unchanged when an
  /// equivalent entry already exists.
  public static func applying(
    _ suggestion: VoiceDictionarySuggestion,
    to dictionary: PersonalDictionary
  ) -> PersonalDictionary {
    var updated = dictionary
    switch suggestion {
    case .vocabulary(let term):
      if !dictionary.vocabulary.contains(where: { $0.lowercased() == term.lowercased() }) {
        updated.vocabulary.append(term)
      }
    case .replacement(let spokenForm, let replacement):
      if !dictionary.replacements.contains(where: {
        $0.spokenForm.lowercased() == spokenForm.lowercased()
      }) {
        updated.replacements.append(
          PersonalDictionaryReplacement(spokenForm: spokenForm, replacement: replacement)
        )
      }
    }
    return updated
  }

  struct Word: Equatable {
    /// The word without surrounding punctuation, as the user wrote it.
    let text: String
    /// Case-insensitive comparison key.
    let key: String
  }

  struct Span: Equatable {
    let source: [Word]
    let target: [Word]
  }

  static func words(in text: String) -> [Word] {
    text.split(whereSeparator: \.isWhitespace).compactMap { token in
      let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
      return trimmed.isEmpty ? nil : Word(text: trimmed, key: trimmed.lowercased())
    }
  }

  /// Groups the words outside a longest common subsequence into edited spans.
  static func editedSpans(source: [Word], target: [Word]) -> [Span] {
    let rows = source.count
    let columns = target.count
    var lengths = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
    for row in stride(from: rows - 1, through: 0, by: -1) {
      for column in stride(from: columns - 1, through: 0, by: -1) {
        lengths[row][column] =
          source[row].key == target[column].key
          ? lengths[row + 1][column + 1] + 1
          : max(lengths[row + 1][column], lengths[row][column + 1])
      }
    }
    var spans: [Span] = []
    var pendingSource: [Word] = []
    var pendingTarget: [Word] = []
    func flush() {
      if !pendingSource.isEmpty || !pendingTarget.isEmpty {
        spans.append(Span(source: pendingSource, target: pendingTarget))
        pendingSource = []
        pendingTarget = []
      }
    }
    var row = 0
    var column = 0
    while row < rows || column < columns {
      if row < rows, column < columns, source[row].key == target[column].key {
        flush()
        row += 1
        column += 1
      } else if column < columns,
        row == rows || lengths[row][column + 1] >= lengths[row + 1][column]
      {
        pendingTarget.append(target[column])
        column += 1
      } else {
        pendingSource.append(source[row])
        row += 1
      }
    }
    flush()
    return spans
  }

  /// A misheard term replaces one to four words with a name-like spelling.
  static func isTermSubstitution(_ span: Span) -> Bool {
    guard
      (1...maximumSpanWords).contains(span.source.count),
      (1...maximumSpanWords).contains(span.target.count),
      span.target.contains(where: { looksLikeTerm($0.text) })
    else {
      return false
    }
    if span.source.count == 1, span.target.count == 1 {
      return !isInflection(span.source[0].key, span.target[0].key)
    }
    return true
  }

  /// Plain lowercase words are ordinary vocabulary, not names or terms.
  static func looksLikeTerm(_ word: String) -> Bool {
    word.contains(where: { $0.isUppercase || $0.isNumber })
      || word.contains(where: { !$0.isLetter && $0 != "'" })
  }

  static func isInflection(_ first: String, _ second: String) -> Bool {
    let (shorter, longer) = first.count <= second.count ? (first, second) : (second, first)
    return ["s", "es", "ed", "ing"].contains { longer == shorter + $0 }
  }
}
