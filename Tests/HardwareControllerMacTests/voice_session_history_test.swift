import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceSessionHistoryTest {
  @Test
  func unavailableStorageReportsItsTypedFailure() async {
    let failure = VoiceSessionHistoryError.storageUnavailable(
      "Voice History is unavailable."
    )
    let history = UnavailableVoiceSessionHistory(failure: failure)
    let document = VoiceSessionDocument(
      id: UUID(),
      startedAt: Date(),
      endedAt: Date(),
      rawText: "raw",
      editedText: "raw",
      formattedText: "Raw.",
      deliveredText: "Raw.",
      targetApplicationName: "Notes",
      deliveryOutcome: .inserted
    )

    await #expect(throws: failure) {
      try await history.complete(document)
    }
  }
}
