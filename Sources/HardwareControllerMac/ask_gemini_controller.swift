import Foundation
import HardwareControllerCore

/// Receives spoken questions for the Gemini panel.
public protocol AskGeminiPresenting: Sendable {
  func present(question: String) async
}

/// Captures one spoken question with the shared recognizer and hands its final
/// text to the Gemini panel. It never captures, reads, or writes the focused
/// app, so the app in front (a game, say) keeps focus and keyboard.
public actor AskGeminiController {
  public typealias SnapshotHandler = @Sendable (TranscriptionSnapshot) -> Void

  /// Names the destination in the transcription indicator.
  static let destinationName = "Gemini"

  private let speech: OwnedTranscriptionController
  private let preparedTargeter: PreparedFocusedTextTargeter
  private let presenter: any AskGeminiPresenting
  private let snapshotHandler: SnapshotHandler
  private let mailbox: TranscriptionSnapshotMailbox
  private var observationTask: Task<Void, Never>?
  private var presentedSessionID: UUID?

  public init(
    factory: any SpeechRecognitionSessionCreating,
    microphone: any MicrophoneCapturing,
    authorization: any TranscriptionAuthorizationProviding,
    presenter: any AskGeminiPresenting,
    locale: Locale = .current,
    finalizationTimeout: Duration = .seconds(5),
    snapshotHandler: @escaping SnapshotHandler = { _ in }
  ) {
    let preparedTargeter = PreparedFocusedTextTargeter()
    let mailbox = TranscriptionSnapshotMailbox()
    speech = OwnedTranscriptionController(
      factory: factory,
      microphone: microphone,
      targeter: preparedTargeter,
      writer: DiscardingTranscriptWriter(),
      authorization: authorization,
      locale: locale,
      finalizationTimeout: finalizationTimeout,
      snapshotHandler: mailbox.publish
    )
    self.preparedTargeter = preparedTargeter
    self.presenter = presenter
    self.snapshotHandler = snapshotHandler
    self.mailbox = mailbox
  }

  public func handle(_ command: DictationCommand) async {
    startObservingIfNeeded()
    if command == .begin {
      preparedTargeter.prepare(
        .detachedFinalOnly(applicationName: Self.destinationName)
      )
    }
    await speech.handle(command)
  }

  /// Cancels any session, releases recognition, and stops observing.
  public func shutdown() async {
    await speech.shutdown()
    preparedTargeter.clear()
    mailbox.finish()
    await observationTask?.value
    observationTask = nil
  }

  private func startObservingIfNeeded() {
    guard observationTask == nil else {
      return
    }
    let mailbox = mailbox
    observationTask = Task { [weak self, mailbox] in
      for await snapshot in mailbox.stream {
        await self?.receive(snapshot)
      }
    }
  }

  /// Presents each completed session once. Empty speech presents nothing;
  /// the indicator already shows the session ended.
  private func receive(_ snapshot: TranscriptionSnapshot) async {
    snapshotHandler(snapshot)
    guard
      snapshot.phase == .completed,
      let sessionID = snapshot.sessionID,
      sessionID != presentedSessionID
    else {
      return
    }
    presentedSessionID = sessionID
    let question = snapshot.finalText.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !question.isEmpty else {
      return
    }
    await presenter.present(question: question)
  }
}
