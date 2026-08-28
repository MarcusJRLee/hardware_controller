import Foundation
import HardwareControllerCore

/// Captures a fresh post-countdown target lease for explicit History insertion.
public struct FocusedVoiceHistoryRedeliverer:
  VoiceHistoryRedelivering
{
  private let targeter: any FocusedTextTargeting
  private let writer: any TranscriptWriting
  private let wait: @Sendable () async throws -> Void

  public init(delay: Duration = .seconds(3)) {
    targeter = AccessibilityFocusedTextTargeting()
    let targeter = AccessibilityFocusedTextTargeting()
    writer = SafeTranscriptWriter(
      targeter: targeter,
      inserter: AdaptiveFocusedTextInserter()
    )
    wait = {
      try await Task.sleep(for: delay)
    }
  }

  init(
    targeter: any FocusedTextTargeting,
    writer: any TranscriptWriting,
    wait: @escaping @Sendable () async throws -> Void
  ) {
    self.targeter = targeter
    self.writer = writer
    self.wait = wait
  }

  public func redeliver(_ text: String) async throws {
    try await wait()
    let target = try targeter.capture().guardedDeliveryCopy()
    try writer.insert(text, into: target)
  }
}
