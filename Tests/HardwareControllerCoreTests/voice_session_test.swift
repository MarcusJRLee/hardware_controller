import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceSessionTest {
  @Test
  func legacyDocumentDefaultsToMicrophoneCaptureInput() throws {
    let json = """
      {
        "id":"00000000-0000-0000-0000-000000000001",
        "startedAt":0,
        "endedAt":1,
        "rawText":"raw",
        "editedText":"raw",
        "formattedText":"Raw.",
        "deliveredText":"Raw.",
        "deliveryOutcome":"inserted"
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let document = try decoder.decode(
      VoiceSessionDocument.self,
      from: Data(json.utf8)
    )

    #expect(document.inputKind == .microphoneCapture)
  }

  @Test
  func deliveryFailuresMapToStableHistoryReasons() {
    #expect(
      VoiceSessionDeliveryFailureReason(.focusChanged)
        == .focusChanged
    )
    #expect(
      VoiceSessionDeliveryFailureReason(.processChanged)
        == .processChanged
    )
    #expect(
      VoiceSessionDeliveryFailureReason(.secureTextField)
        == .secureStatusChanged
    )
    #expect(
      VoiceSessionDeliveryFailureReason(.caretChanged)
        == .caretChanged
    )
    #expect(
      VoiceSessionDeliveryFailureReason(.insertionFailed)
        == .insertionRejected
    )
    #expect(
      VoiceSessionDeliveryFailureReason(.modelUnavailable) == nil
    )
  }
}
