import Foundation
import Testing

@testable import HardwareControllerCore

struct TranscriptionTests {
  @Test
  func completeSessionOwnsEveryVisiblePhase() {
    let sessionID = UUID()
    var machine = TranscriptionSessionStateMachine()

    let began = machine.apply(
      .begin(
        sessionID: sessionID,
        targetApplicationName: "TextEdit"
      )
    )
    #expect(began)
    #expect(machine.snapshot.phase == .preparing)
    let started = machine.apply(.listeningStarted)
    #expect(started)
    #expect(machine.snapshot.phase == .listening)
    let receivedVolatile = machine.apply(
      .transcript(.provisional("hello wor"))
    )
    #expect(receivedVolatile)
    #expect(machine.snapshot.volatileText == "hello wor")
    let receivedFinal = machine.apply(
      .transcript(.committed("hello world"))
    )
    #expect(receivedFinal)
    #expect(machine.snapshot.finalText == "hello world")
    #expect(machine.snapshot.volatileText.isEmpty)
    let finishing = machine.apply(.finishRequested)
    #expect(finishing)
    #expect(machine.snapshot.phase == .finalizing)
    let receivedLastFinal = machine.apply(
      .transcript(.committed("hello world again."))
    )
    #expect(receivedLastFinal)
    #expect(machine.snapshot.finalText == "hello world again.")
    let completed = machine.apply(.completed)
    #expect(completed)
    #expect(machine.snapshot.phase == .completed)
    #expect(machine.snapshot.sessionID == sessionID)
    #expect(machine.snapshot.targetApplicationName == "TextEdit")
  }

  @Test
  func releaseDuringPreparationFinalizesWithoutListeningState() {
    var machine = TranscriptionSessionStateMachine()

    let began = machine.apply(
      .begin(
        sessionID: UUID(),
        targetApplicationName: "Notes"
      )
    )
    #expect(began)
    let finishing = machine.apply(.finishRequested)
    #expect(finishing)
    #expect(machine.snapshot.phase == .finalizing)
    let started = machine.apply(.listeningStarted)
    #expect(!started)
    let completed = machine.apply(.completed)
    #expect(completed)
    #expect(machine.snapshot.phase == .completed)
  }

  @Test
  func failureRetainsRecoverableFinalText() {
    var machine = TranscriptionSessionStateMachine()
    _ = machine.apply(
      .begin(
        sessionID: UUID(),
        targetApplicationName: "Mail"
      )
    )
    _ = machine.apply(.listeningStarted)
    _ = machine.apply(.transcript(.committed("Keep this")))
    _ = machine.apply(
      .transcript(
        .provisional(
          "private partial",
          committedText: "Keep this"
        )
      )
    )

    let failed = machine.apply(.failed(.focusChanged))
    #expect(failed)
    #expect(machine.snapshot.phase == .failed)
    #expect(machine.snapshot.failure == .focusChanged)
    #expect(machine.snapshot.finalText == "Keep this")
    #expect(machine.snapshot.volatileText.isEmpty)
    #expect(machine.snapshot.hasRecoverableTranscript)
  }

  @Test
  func aNewSessionClearsThePriorTranscriptAndFailure() {
    var machine = TranscriptionSessionStateMachine()
    _ = machine.apply(
      .begin(
        sessionID: UUID(),
        targetApplicationName: "First"
      )
    )
    _ = machine.apply(.failed(.microphonePermissionDenied))

    let nextID = UUID()
    let began = machine.apply(
      .begin(
        sessionID: nextID,
        targetApplicationName: "Second"
      )
    )
    #expect(began)
    #expect(machine.snapshot.sessionID == nextID)
    #expect(machine.snapshot.targetApplicationName == "Second")
    #expect(machine.snapshot.failure == nil)
    #expect(machine.snapshot.finalText.isEmpty)
  }

  @Test
  func cancelMovesThroughCancelingAndBackToIdle() {
    var machine = TranscriptionSessionStateMachine()
    _ = machine.apply(
      .begin(
        sessionID: UUID(),
        targetApplicationName: "TextEdit"
      )
    )
    _ = machine.apply(.listeningStarted)

    let canceling = machine.apply(.cancelRequested)
    #expect(canceling)
    #expect(machine.snapshot.phase == .canceling)
    let cancelled = machine.apply(.cancelled)
    #expect(cancelled)
    #expect(machine.snapshot == .idle)
  }

  @Test
  func invalidEventsCannotInventARecordingSession() {
    var machine = TranscriptionSessionStateMachine()

    let started = machine.apply(.listeningStarted)
    let finishing = machine.apply(.finishRequested)
    let updated = machine.apply(
      .transcript(.committed("unexpected"))
    )
    let completed = machine.apply(.completed)

    #expect(!started)
    #expect(!finishing)
    #expect(!updated)
    #expect(!completed)
    #expect(machine.snapshot == .idle)
  }

  @Test
  func finalSegmentsKeepPunctuationAndInsertWordSpacing() {
    var transcript = ""

    TranscriptAccumulator.append("Hello", to: &transcript)
    TranscriptAccumulator.append(",", to: &transcript)
    TranscriptAccumulator.append("world.", to: &transcript)
    TranscriptAccumulator.append(" Already spaced", to: &transcript)

    #expect(transcript == "Hello, world. Already spaced")
  }

  @Test
  func cumulativeRevisionReplacesProvisionalText() {
    var machine = TranscriptionSessionStateMachine()
    _ = machine.apply(
      .begin(
        sessionID: UUID(),
        targetApplicationName: "Terminal"
      )
    )
    _ = machine.apply(.listeningStarted)

    _ = machine.apply(
      .transcript(.provisional("hard ware"))
    )
    _ = machine.apply(
      .transcript(.provisional("hardware controller"))
    )

    #expect(machine.snapshot.finalText.isEmpty)
    #expect(
      machine.snapshot.volatileText
        == "hardware controller"
    )
  }

  @Test
  func revisionDisplayTextJoinsCommittedAndProvisional() {
    let revision = TranscriptRevision.provisional(
      "again.",
      committedText: "Hello world"
    )

    #expect(revision.displayText == "Hello world again.")
  }
}
