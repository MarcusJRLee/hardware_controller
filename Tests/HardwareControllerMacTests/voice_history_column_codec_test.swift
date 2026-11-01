import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct VoiceHistoryColumnCodecTest {
  private typealias Codec = VoiceHistoryColumnCodec

  /// Null columns decode to absence and known raw values to their cases.
  @Test
  func enumColumnsDecodeNullAndKnownValues() throws {
    #expect(try Codec.optionalAudioExpirationReason(nil) == nil)
    #expect(try Codec.optionalAudioExpirationReason("age_limit") == .ageLimit)
    #expect(try Codec.optionalRecoveryKind("interrupted_capture") == .interruptedCapture)
    #expect(try Codec.historyProvider("ollama") == .ollama)
    let id = UUID()
    #expect(try Codec.optionalUUID(id.uuidString) == id)
  }

  /// An unknown stored value is a typed storage failure, never a silent default.
  @Test
  func unknownStoredValuesFailClosed() {
    let attempts: [() throws -> Void] = [
      { _ = try Codec.optionalAudioExpirationReason("forever") },
      { _ = try Codec.optionalRecoveryKind("guess") },
      { _ = try Codec.optionalUUID("not-a-uuid") },
      { _ = try Codec.historyProvider("cloud") },
      { _ = try Codec.timedSpans(from: "{") },
    ]
    for attempt in attempts {
      #expect(throws: VoiceSessionHistoryError.self) { try attempt() }
    }
  }

  /// Timed spans survive a round trip, and no spans store as null.
  @Test
  func timedSpansRoundTrip() throws {
    let spans = [
      VoiceHistoryTimedSpan(startMilliseconds: 0, endMilliseconds: 420, text: "send"),
      VoiceHistoryTimedSpan(startMilliseconds: 420, endMilliseconds: 900, text: " it"),
    ]
    let encoded = try #require(try Codec.encodedTimedSpans(spans))
    #expect(try Codec.timedSpans(from: encoded) == spans)
    #expect(try Codec.encodedTimedSpans([]) == nil)
    #expect(try Codec.timedSpans(from: nil).isEmpty)
  }
}
