@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryRedelivererTest {
  @Test
  func waitsThenCapturesAFreshGuardedCaretAndInsertsOnce() async throws {
    let sequence = RedeliverySequence()
    let targeter = RedeliveryTargeter(sequence: sequence)
    let writer = RedeliveryWriter(sequence: sequence)
    let redeliverer = FocusedVoiceHistoryRedeliverer(
      targeter: targeter,
      writer: writer,
      wait: { sequence.append("wait") }
    )

    try await redeliverer.redeliver("Recovered text.")

    #expect(sequence.values == ["wait", "capture", "insert"])
    #expect(writer.inserted == ["Recovered text."])
    #expect(writer.guardedCaretValues == [true])
  }

  @Test
  func nonemptySelectionIsRejectedBeforeMutation() async {
    let sequence = RedeliverySequence()
    let targeter = RedeliveryTargeter(
      sequence: sequence,
      selectedRange: FocusedTextRange(location: 4, length: 2)
    )
    let writer = RedeliveryWriter(sequence: sequence)
    let redeliverer = FocusedVoiceHistoryRedeliverer(
      targeter: targeter,
      writer: writer,
      wait: {}
    )

    await #expect(throws: TranscriptionFailure.noFocusedTextField) {
      try await redeliverer.redeliver("Do not insert.")
    }
    #expect(writer.inserted.isEmpty)
  }
}

private final class RedeliverySequence: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValues: [String] = []

  var values: [String] { lock.withLock { storedValues } }

  func append(_ value: String) {
    lock.withLock { storedValues.append(value) }
  }
}

private struct RedeliveryTargeter: FocusedTextTargeting {
  let sequence: RedeliverySequence
  let selectedRange: FocusedTextRange

  init(
    sequence: RedeliverySequence,
    selectedRange: FocusedTextRange = FocusedTextRange(
      location: 4,
      length: 0
    )
  ) {
    self.sequence = sequence
    self.selectedRange = selectedRange
  }

  func capture() throws -> FocusedTextTarget {
    sequence.append("capture")
    return FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes",
      selectedRange: selectedRange
    )
  }

  func isStillFocused(_ target: FocusedTextTarget) -> Bool { true }
}

private final class RedeliveryWriter:
  TranscriptWriting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let sequence: RedeliverySequence
  private var storedInserted: [String] = []
  private var storedGuardedCaretValues: [Bool] = []

  init(sequence: RedeliverySequence) {
    self.sequence = sequence
  }

  var inserted: [String] { lock.withLock { storedInserted } }
  var guardedCaretValues: [Bool] {
    lock.withLock { storedGuardedCaretValues }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {
    sequence.append("insert")
    lock.withLock {
      storedInserted.append(text)
      storedGuardedCaretValues.append(target.guardsCapturedCaret)
    }
  }
}
