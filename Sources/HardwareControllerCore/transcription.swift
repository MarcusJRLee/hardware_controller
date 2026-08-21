import Foundation

public enum TranscriptionPhase: String, Equatable, Sendable {
  case idle
  case preparing
  case listening
  case finalizing
  case canceling
  case completed
  case failed
}

public enum TranscriptionFailure: Equatable, Error, Sendable {
  case microphonePermissionDenied
  case speechRecognitionPermissionDenied
  case localeUnsupported
  case modelUnavailable
  case noFocusedTextField
  case secureTextField
  case focusChanged
  case caretChanged
  case audioUnavailable(String)
  case recognitionFailed(String)
  case insertionFailed
}

public struct TranscriptRevision: Equatable, Sendable {
  public let committedText: String
  public let provisionalText: String

  public init(
    committedText: String,
    provisionalText: String
  ) {
    self.committedText = committedText
    self.provisionalText = provisionalText
  }

  public static func provisional(
    _ text: String,
    committedText: String = ""
  ) -> Self {
    Self(
      committedText: committedText,
      provisionalText: text
    )
  }

  public static func committed(_ text: String) -> Self {
    Self(committedText: text, provisionalText: "")
  }

  public var displayText: String {
    var text = committedText
    TranscriptAccumulator.append(provisionalText, to: &text)
    return text
  }
}

public struct TranscriptionSnapshot: Equatable, Sendable {
  public let sessionID: UUID?
  public let phase: TranscriptionPhase
  public let volatileText: String
  public let finalText: String
  public let targetApplicationName: String?
  public let failure: TranscriptionFailure?
  public let showsInlineProvisionalText: Bool

  public init(
    sessionID: UUID?,
    phase: TranscriptionPhase,
    volatileText: String,
    finalText: String,
    targetApplicationName: String?,
    failure: TranscriptionFailure?,
    showsInlineProvisionalText: Bool = false
  ) {
    self.sessionID = sessionID
    self.phase = phase
    self.volatileText = volatileText
    self.finalText = finalText
    self.targetApplicationName = targetApplicationName
    self.failure = failure
    self.showsInlineProvisionalText =
      showsInlineProvisionalText
  }

  public static let idle = TranscriptionSnapshot(
    sessionID: nil,
    phase: .idle,
    volatileText: "",
    finalText: "",
    targetApplicationName: nil,
    failure: nil,
    showsInlineProvisionalText: false
  )

  public var hasRecoverableTranscript: Bool {
    !finalText.isEmpty
  }
}

public enum TranscriptionSessionEvent: Equatable, Sendable {
  case begin(
    sessionID: UUID,
    targetApplicationName: String,
    showsInlineProvisionalText: Bool = false
  )
  case listeningStarted
  case transcript(TranscriptRevision)
  case finishRequested
  case cancelRequested
  case completed
  case failed(TranscriptionFailure)
  case cancelled
  case reset
}

public struct TranscriptionSessionStateMachine: Sendable {
  public private(set) var snapshot: TranscriptionSnapshot

  public init(snapshot: TranscriptionSnapshot = .idle) {
    self.snapshot = snapshot
  }

  @discardableResult
  public mutating func apply(
    _ event: TranscriptionSessionEvent
  ) -> Bool {
    switch event {
    case .begin(
      let sessionID,
      let targetApplicationName,
      let showsInlineProvisionalText
    ):
      guard [.idle, .completed, .failed].contains(snapshot.phase) else {
        return false
      }
      snapshot = TranscriptionSnapshot(
        sessionID: sessionID,
        phase: .preparing,
        volatileText: "",
        finalText: "",
        targetApplicationName: targetApplicationName,
        failure: nil,
        showsInlineProvisionalText:
          showsInlineProvisionalText
      )

    case .listeningStarted:
      guard snapshot.phase == .preparing else {
        return false
      }
      replace(phase: .listening)

    case .transcript(let revision):
      guard [.listening, .finalizing].contains(snapshot.phase) else {
        return false
      }
      replace(
        volatileText: revision.provisionalText,
        finalText: revision.committedText
      )

    case .finishRequested:
      guard [.preparing, .listening].contains(snapshot.phase) else {
        return false
      }
      replace(phase: .finalizing)

    case .cancelRequested:
      guard
        [.preparing, .listening, .finalizing]
          .contains(snapshot.phase)
      else {
        return false
      }
      replace(phase: .canceling, volatileText: "")

    case .completed:
      guard [.listening, .finalizing].contains(snapshot.phase) else {
        return false
      }
      replace(phase: .completed, volatileText: "")

    case .failed(let failure):
      guard
        [.preparing, .listening, .finalizing, .canceling]
          .contains(snapshot.phase)
      else {
        return false
      }
      replace(
        phase: .failed,
        volatileText: "",
        failure: failure
      )

    case .cancelled:
      guard snapshot.phase == .canceling else {
        return false
      }
      snapshot = .idle

    case .reset:
      guard [.completed, .failed].contains(snapshot.phase) else {
        return false
      }
      snapshot = .idle
    }
    return true
  }

  private mutating func replace(
    phase: TranscriptionPhase? = nil,
    volatileText: String? = nil,
    finalText: String? = nil,
    failure: TranscriptionFailure?? = nil
  ) {
    snapshot = TranscriptionSnapshot(
      sessionID: snapshot.sessionID,
      phase: phase ?? snapshot.phase,
      volatileText: volatileText ?? snapshot.volatileText,
      finalText: finalText ?? snapshot.finalText,
      targetApplicationName: snapshot.targetApplicationName,
      failure: failure ?? snapshot.failure,
      showsInlineProvisionalText:
        snapshot.showsInlineProvisionalText
    )
  }
}

public enum TranscriptAccumulator {
  public static func append(
    _ segment: String,
    to transcript: inout String
  ) {
    guard !segment.isEmpty else {
      return
    }
    guard !transcript.isEmpty else {
      transcript = segment
      return
    }

    if transcript.last?.isWhitespace == true
      || segment.first?.isWhitespace == true
      || segment.first.map(Self.isTrailingPunctuation) == true
    {
      transcript.append(segment)
    } else {
      transcript.append(" ")
      transcript.append(segment)
    }
  }

  private static func isTrailingPunctuation(
    _ character: Character
  ) -> Bool {
    ".,!?;:…)]}".contains(character)
  }
}
