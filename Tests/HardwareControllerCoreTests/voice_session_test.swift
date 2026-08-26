import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceSessionTest {
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
