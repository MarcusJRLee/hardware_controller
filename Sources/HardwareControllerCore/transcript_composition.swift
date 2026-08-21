import Foundation

public enum TranscriptCompositionFailure:
  Equatable,
  Error,
  Sendable
{
  case committedTextChanged
}

public struct TranscriptCompositionMutation:
  Equatable,
  Sendable
{
  public let expectedCaretOffset: Int
  public let replacementOffset: Int
  public let replacementLength: Int
  public let replacementText: String

  public init(
    expectedCaretOffset: Int,
    replacementOffset: Int,
    replacementLength: Int,
    replacementText: String
  ) {
    self.expectedCaretOffset = expectedCaretOffset
    self.replacementOffset = replacementOffset
    self.replacementLength = replacementLength
    self.replacementText = replacementText
  }
}

public struct TranscriptComposition: Sendable {
  private var deliveredRevision = TranscriptRevision.committed("")

  public init() {}

  public var revision: TranscriptRevision {
    deliveredRevision
  }

  public mutating func apply(
    _ revision: TranscriptRevision
  ) throws -> TranscriptCompositionMutation? {
    let stablePrefix = deliveredRevision.committedText
    guard revision.committedText.hasPrefix(stablePrefix) else {
      throw TranscriptCompositionFailure.committedTextChanged
    }

    let previousText = deliveredRevision.displayText
    let replacementStart =
      previousText.index(
        previousText.startIndex,
        offsetBy: stablePrefix.count
      )
    let previousSuffix = String(previousText[replacementStart...])

    let nextText = revision.displayText
    guard nextText.hasPrefix(stablePrefix) else {
      throw TranscriptCompositionFailure.committedTextChanged
    }
    let nextStart =
      nextText.index(
        nextText.startIndex,
        offsetBy: stablePrefix.count
      )
    let nextSuffix = String(nextText[nextStart...])

    deliveredRevision = revision
    guard previousSuffix != nextSuffix else {
      return nil
    }

    return TranscriptCompositionMutation(
      expectedCaretOffset: previousText.utf16.count,
      replacementOffset: stablePrefix.utf16.count,
      replacementLength: previousSuffix.utf16.count,
      replacementText: nextSuffix
    )
  }

  public mutating func cancel()
    -> TranscriptCompositionMutation?
  {
    let committedText = deliveredRevision.committedText
    let previousText = deliveredRevision.displayText
    let suffixStart =
      previousText.index(
        previousText.startIndex,
        offsetBy: committedText.count
      )
    let suffix = String(previousText[suffixStart...])
    deliveredRevision = .committed(committedText)

    guard !suffix.isEmpty else {
      return nil
    }
    return TranscriptCompositionMutation(
      expectedCaretOffset: previousText.utf16.count,
      replacementOffset: committedText.utf16.count,
      replacementLength: suffix.utf16.count,
      replacementText: ""
    )
  }
}
