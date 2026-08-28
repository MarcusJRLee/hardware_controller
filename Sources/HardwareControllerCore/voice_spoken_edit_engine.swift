import Foundation

public struct VoiceSpokenEditEngine: Sendable {
  private enum ListKind {
    case ordered
    case unordered
  }

  private struct ListState {
    let kind: ListKind
    let itemNumber: Int
    let itemContentStartUTF8Offset: Int
  }

  private struct Edit {
    let kind: VoiceSpokenEditOperationKind
    let affectedStart: String.Index
    let replacementText: String
    let nextListState: ListState?
    let changesListState: Bool
  }

  private enum Command: String {
    case scratchThat = "scratch that"
    case deleteThatSentence = "delete that sentence"
    case newParagraph = "new paragraph"
    case startNumberedList = "start a numbered list"
    case startBulletList = "start a bullet list"
    case startBulletedList = "start a bulleted list"
    case bullet = "bullet"
    case nextItem = "next item"
    case endList = "end list"
  }

  private let revision: Int

  public init() {
    revision = VoiceSpokenEditResult.currentRevision
  }

  init(revision: Int) {
    self.revision = revision
  }

  public func apply(to sourceText: String) -> VoiceSpokenEditResult {
    let matches = commandExpression.matches(
      in: sourceText,
      range: NSRange(sourceText.startIndex..., in: sourceText)
    )
    var sourceCursor = sourceText.startIndex
    var sourceCursorUTF8Offset = 0
    var editedText = ""
    var operations: [VoiceSpokenEditOperation] = []
    var listState: ListState?

    for match in matches {
      guard let range = Range(match.range, in: sourceText) else {
        continue
      }
      let sourcePrefix = sourceText[sourceCursor..<range.lowerBound]
      let sourceStartUTF8Offset =
        sourceCursorUTF8Offset + sourcePrefix.utf8.count
      editedText.append(contentsOf: sourcePrefix)
      let matchedText = String(sourceText[range])
      let literalCommand = literalCommandText(matchedText)
      if let literalCommand {
        let affectedOffset = editedText.utf8.count
        operations.append(
          VoiceSpokenEditOperation(
            kind: .preserveLiteralCommand,
            sourceUTF8StartOffset: sourceStartUTF8Offset,
            sourceUTF8EndOffset:
              sourceStartUTF8Offset + matchedText.utf8.count,
            editedUTF8StartOffset: affectedOffset,
            editedUTF8EndOffset: affectedOffset,
            replacementText: literalCommand
          )
        )
        editedText.append(literalCommand)
        sourceCursor = range.upperBound
        sourceCursorUTF8Offset =
          sourceStartUTF8Offset + matchedText.utf8.count
        continue
      }
      guard
        let command = command(from: matchedText),
        let edit = edit(
          for: command,
          editedText: editedText,
          listState: listState
        )
      else {
        editedText.append(matchedText)
        sourceCursor = range.upperBound
        sourceCursorUTF8Offset =
          sourceStartUTF8Offset + matchedText.utf8.count
        continue
      }

      let sourceEnd = extendedCommandEnd(
        in: sourceText,
        from: range.upperBound
      )
      let affectedStartOffset = editedText.voiceUTF8Offset(
        of: edit.affectedStart
      )
      let affectedEndOffset = editedText.utf8.count
      let sourceEndUTF8Offset =
        sourceStartUTF8Offset
        + sourceText[range.lowerBound..<sourceEnd].utf8.count
      editedText.replaceSubrange(
        edit.affectedStart..<editedText.endIndex,
        with: edit.replacementText
      )
      operations.append(
        VoiceSpokenEditOperation(
          kind: edit.kind,
          sourceUTF8StartOffset: sourceStartUTF8Offset,
          sourceUTF8EndOffset: sourceEndUTF8Offset,
          editedUTF8StartOffset: affectedStartOffset,
          editedUTF8EndOffset: affectedEndOffset,
          replacementText: edit.replacementText
        )
      )
      if edit.changesListState {
        listState = edit.nextListState
      }
      sourceCursor = sourceEnd
      sourceCursorUTF8Offset = sourceEndUTF8Offset
    }

    editedText.append(contentsOf: sourceText[sourceCursor...])
    if !operations.isEmpty {
      editedText = editedText.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    }
    return VoiceSpokenEditResult(
      revision: revision,
      sourceText: sourceText,
      editedText: editedText,
      operations: operations
    )
  }

  private func edit(
    for command: Command,
    editedText: String,
    listState: ListState?
  ) -> Edit? {
    switch command {
    case .scratchThat:
      return destructiveEdit(
        kind: .deleteCurrentClause,
        boundaries: Self.clauseBoundaries,
        editedText: editedText,
        listState: listState
      )
    case .deleteThatSentence:
      return destructiveEdit(
        kind: .deleteCurrentSentence,
        boundaries: Self.sentenceBoundaries,
        editedText: editedText,
        listState: listState
      )
    case .newParagraph:
      return paragraphEdit(
        editedText: editedText,
        listState: listState
      )
    case .startNumberedList:
      return beginListEdit(
        kind: .ordered,
        editedText: editedText,
        listState: listState
      )
    case .startBulletList, .startBulletedList:
      return beginListEdit(
        kind: .unordered,
        editedText: editedText,
        listState: listState
      )
    case .bullet:
      guard let listState else {
        guard
          !hasMeaningfulText(editedText)
            || hasTrailingListCue(editedText)
        else {
          return nil
        }
        return beginListEdit(
          kind: .unordered,
          editedText: editedText,
          listState: nil
        )
      }
      guard listState.kind == .unordered else {
        return nil
      }
      return nextListItemEdit(
        editedText: editedText,
        listState: listState
      )
    case .nextItem:
      guard let listState else {
        return nil
      }
      return nextListItemEdit(
        editedText: editedText,
        listState: listState
      )
    case .endList:
      return endListEdit(
        editedText: editedText,
        listState: listState
      )
    }
  }

  private func destructiveEdit(
    kind: VoiceSpokenEditOperationKind,
    boundaries: Set<Character>,
    editedText: String,
    listState: ListState?
  ) -> Edit? {
    guard
      var start = deletionStart(
        in: editedText,
        boundaries: boundaries
      )
    else {
      return nil
    }
    if let listState,
      let itemStart = editedText.voiceIndex(
        atUTF8Offset: listState.itemContentStartUTF8Offset
      ),
      itemStart > start
    {
      start = itemStart
    }
    guard hasMeaningfulText(editedText[start...]) else {
      return nil
    }
    let replacement: String
    if start == editedText.startIndex
      || editedText[editedText.index(before: start)].isWhitespace
    {
      replacement = ""
    } else {
      replacement = " "
    }
    return Edit(
      kind: kind,
      affectedStart: start,
      replacementText: replacement,
      nextListState: listState,
      changesListState: false
    )
  }

  private func paragraphEdit(
    editedText: String,
    listState: ListState?
  ) -> Edit? {
    let affectedStart = trailingWhitespaceStart(in: editedText)
    if let listState {
      guard
        let itemStart = editedText.voiceIndex(
          atUTF8Offset: listState.itemContentStartUTF8Offset
        ),
        itemStart <= affectedStart,
        hasMeaningfulText(editedText[itemStart..<affectedStart])
      else {
        return nil
      }
      return nextListItemEdit(
        editedText: editedText,
        listState: listState
      )
    }
    guard
      hasMeaningfulText(editedText[..<affectedStart]),
      !editedText[affectedStart...].contains("\n")
    else {
      return nil
    }
    return Edit(
      kind: .insertParagraphBreak,
      affectedStart: affectedStart,
      replacementText: "\n\n",
      nextListState: nil,
      changesListState: false
    )
  }

  private func beginListEdit(
    kind: ListKind,
    editedText: String,
    listState: ListState?
  ) -> Edit? {
    guard listState == nil else {
      return nil
    }
    let affectedStart = trailingWhitespaceStart(in: editedText)
    let marker = kind == .ordered ? "1. " : "- "
    let replacement =
      hasMeaningfulText(editedText[..<affectedStart])
      ? "\n\n\(marker)" : marker
    return Edit(
      kind: kind == .ordered ? .beginOrderedList : .beginUnorderedList,
      affectedStart: affectedStart,
      replacementText: replacement,
      nextListState: ListState(
        kind: kind,
        itemNumber: 1,
        itemContentStartUTF8Offset:
          editedText.voiceUTF8Offset(of: affectedStart)
          + replacement.utf8.count
      ),
      changesListState: true
    )
  }

  private func nextListItemEdit(
    editedText: String,
    listState: ListState
  ) -> Edit? {
    let affectedStart = trailingWhitespaceStart(in: editedText)
    guard
      let itemStart = editedText.voiceIndex(
        atUTF8Offset: listState.itemContentStartUTF8Offset
      ),
      itemStart <= affectedStart,
      hasMeaningfulText(editedText[itemStart..<affectedStart])
    else {
      return nil
    }
    let nextNumber = listState.itemNumber + 1
    let replacement =
      listState.kind == .ordered ? "\n\(nextNumber). " : "\n- "
    return Edit(
      kind: listState.kind == .ordered
        ? .beginOrderedListItem : .beginUnorderedListItem,
      affectedStart: affectedStart,
      replacementText: replacement,
      nextListState: ListState(
        kind: listState.kind,
        itemNumber: nextNumber,
        itemContentStartUTF8Offset:
          editedText.voiceUTF8Offset(of: affectedStart)
          + replacement.utf8.count
      ),
      changesListState: true
    )
  }

  private func endListEdit(
    editedText: String,
    listState: ListState?
  ) -> Edit? {
    guard let listState,
      let itemStart = editedText.voiceIndex(
        atUTF8Offset: listState.itemContentStartUTF8Offset
      )
    else {
      return nil
    }
    let affectedStart = trailingWhitespaceStart(in: editedText)
    guard itemStart <= affectedStart,
      hasMeaningfulText(editedText[itemStart..<affectedStart])
    else {
      return nil
    }
    return Edit(
      kind: .endList,
      affectedStart: affectedStart,
      replacementText: "\n\n",
      nextListState: nil,
      changesListState: true
    )
  }

  private func deletionStart(
    in text: String,
    boundaries: Set<Character>
  ) -> String.Index? {
    var contentEnd = text.endIndex
    while contentEnd > text.startIndex,
      text[text.index(before: contentEnd)].isWhitespace
    {
      contentEnd = text.index(before: contentEnd)
    }
    while contentEnd > text.startIndex,
      boundaries.contains(text[text.index(before: contentEnd)])
    {
      contentEnd = text.index(before: contentEnd)
    }
    guard contentEnd > text.startIndex else {
      return nil
    }
    var cursor = contentEnd
    while cursor > text.startIndex {
      let previous = text.index(before: cursor)
      if boundaries.contains(text[previous]) {
        return cursor
      }
      cursor = previous
    }
    return text.startIndex
  }

  private func trailingWhitespaceStart(in text: String) -> String.Index {
    var cursor = text.endIndex
    while cursor > text.startIndex,
      text[text.index(before: cursor)].isWhitespace
    {
      cursor = text.index(before: cursor)
    }
    return cursor
  }

  private func hasMeaningfulText<S: StringProtocol>(_ text: S) -> Bool {
    text.unicodeScalars.contains { scalar in
      !CharacterSet.whitespacesAndNewlines.contains(scalar)
        && !CharacterSet.punctuationCharacters.contains(scalar)
    }
  }

  private func hasTrailingListCue(_ text: String) -> Bool {
    text.range(
      of:
        #"(?i)\b(?:(?:grocery|shopping|packing|task|to-do)\s+)?list\s*[:,-]?\s*$"#,
      options: .regularExpression
    ) != nil
  }

  private func literalCommandText(_ text: String) -> String? {
    let components = text.split(
      maxSplits: 1,
      whereSeparator: { $0.isWhitespace }
    )
    guard components.count == 2,
      components[0].lowercased() == "literal",
      command(from: String(components[1])) != nil
    else {
      return nil
    }
    return String(components[1])
  }

  private func command(from text: String) -> Command? {
    let normalized = text.split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
    guard let command = Command(rawValue: normalized) else {
      return nil
    }
    guard revision >= 2 || Self.revisionOneCommands.contains(command) else {
      return nil
    }
    return command
  }

  private func extendedCommandEnd(
    in text: String,
    from initialEnd: String.Index
  ) -> String.Index {
    var cursor = initialEnd
    while cursor < text.endIndex {
      let character = text[cursor]
      guard
        character == " " || character == "\t"
          || Self.commandTrailingSeparators.contains(character)
      else {
        break
      }
      cursor = text.index(after: cursor)
    }
    return cursor
  }

  private var commandExpression: NSRegularExpression {
    revision >= 2
      ? Self.revisionTwoCommandExpression
      : Self.revisionOneCommandExpression
  }
  private static let revisionOneCommandExpression: NSRegularExpression = {
    do {
      return try NSRegularExpression(
        pattern:
          "(?i)\\b(?:literal[ \\t]+)?(?:scratch[ \\t]+that|delete[ \\t]+that[ \\t]+sentence|new[ \\t]+paragraph|start[ \\t]+a[ \\t]+numbered[ \\t]+list|end[ \\t]+list)\\b"
      )
    } catch {
      preconditionFailure("The fixed spoken-edit command pattern is invalid: \(error)")
    }
  }()
  private static let revisionTwoCommandExpression: NSRegularExpression = {
    do {
      return try NSRegularExpression(
        pattern:
          "(?i)\\b(?:literal[ \\t]+)?(?:scratch[ \\t]+that|delete[ \\t]+that[ \\t]+sentence|new[ \\t]+paragraph|start[ \\t]+a[ \\t]+numbered[ \\t]+list|start[ \\t]+a[ \\t]+bullet(?:ed)?[ \\t]+list|next[ \\t]+item|bullet|end[ \\t]+list)\\b"
      )
    } catch {
      preconditionFailure("The fixed spoken-edit command pattern is invalid: \(error)")
    }
  }()
  private static let revisionOneCommands: Set<Command> = [
    .scratchThat,
    .deleteThatSentence,
    .newParagraph,
    .startNumberedList,
    .endList,
  ]
  private static let clauseBoundaries: Set<Character> = [
    ".", "?", "!", ";", ":", ",", "\n",
  ]
  private static let sentenceBoundaries: Set<Character> = [
    ".", "?", "!", "\n",
  ]
  private static let commandTrailingSeparators: Set<Character> = [
    ".", ",", ";", ":", "?", "!",
  ]
}
