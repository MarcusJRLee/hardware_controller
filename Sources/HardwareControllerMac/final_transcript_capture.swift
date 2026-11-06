import Foundation
import HardwareControllerCore

// Shared pieces that let a workflow reuse `OwnedTranscriptionController` for
// final text only, without it touching the focused app.

/// Hands the transcription controller one pre-captured target per session.
final class PreparedFocusedTextTargeter:
  FocusedTextTargeting,
  @unchecked Sendable
{
  private let underlying: any FocusedTextTargeting
  private let lock = NSLock()
  private var preparedTarget: FocusedTextTarget?

  init(underlying: any FocusedTextTargeting = DetachedFocusedTextTargeting()) {
    self.underlying = underlying
  }

  func prepare(_ target: FocusedTextTarget) {
    lock.withLock {
      preparedTarget = target
    }
  }

  func clear() {
    lock.withLock {
      preparedTarget = nil
    }
  }

  func capture() throws -> FocusedTextTarget {
    try lock.withLock {
      guard let target = preparedTarget else {
        throw TranscriptionFailure.noFocusedTextField
      }
      preparedTarget = nil
      return target
    }
  }

  func isStillFocused(_ target: FocusedTextTarget) -> Bool {
    underlying.isStillFocused(target)
  }

  func ownershipFailure(
    for target: FocusedTextTarget
  ) -> FocusedTextTargetOwnershipFailure? {
    underlying.ownershipFailure(for: target)
  }
}

/// Drops incremental text; the owning workflow reads final text from snapshots.
struct DiscardingTranscriptWriter: TranscriptWriting {
  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {}
}

/// Buffers transcription snapshots for an actor to consume in order.
final class TranscriptionSnapshotMailbox:
  @unchecked Sendable
{
  let stream: AsyncStream<TranscriptionSnapshot>
  private let continuation: AsyncStream<TranscriptionSnapshot>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(32)
    )
  }

  func publish(_ snapshot: TranscriptionSnapshot) {
    continuation.yield(snapshot)
  }

  func finish() {
    continuation.finish()
  }
}

/// Underlying targeter for workflows whose text never goes to the focused app.
struct DetachedFocusedTextTargeting: FocusedTextTargeting {
  func capture() throws -> FocusedTextTarget {
    throw TranscriptionFailure.noFocusedTextField
  }

  func isStillFocused(_ target: FocusedTextTarget) -> Bool {
    true
  }
}
