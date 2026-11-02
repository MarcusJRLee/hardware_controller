import Foundation
import HardwareControllerCore
import Testing

struct SpeechEngineTest {
  /// History names the model, or says Apple ran and why.
  @Test
  func titlesNameTheModelOrTheFallback() {
    let parakeet = SpeechEngineUsage(
      engine: .transcribeCpp,
      modelPackageID: "com.longdevity.asr.parakeet_tdt_v3",
      modelPackageVersion: "d8d8c32-q8_0",
      modelDisplayName: "Parakeet TDT 0.6B v3"
    )
    #expect(parakeet.title == "Parakeet TDT 0.6B v3 · d8d8c32-q8_0")
    #expect(SpeechEngineUsage(engine: .transcribeCpp).title == "transcribe.cpp")
    #expect(SpeechEngineUsage.apple.title == "Apple")
    #expect(
      SpeechEngineUsage(engine: .apple, fallbackReason: .serviceFailed).title
        == "Apple (speech service stopped)")
    #expect(
      SpeechEngineUsage(engine: .apple, fallbackReason: .disabledUntilRelaunch).title
        == "Apple (speech service paused until relaunch)"
    )
  }

  /// Raw values are persisted in preferences and History; they never change.
  @Test
  func persistedValuesAreStable() throws {
    #expect(SpeechEngine.transcribeCpp.rawValue == "transcribe_cpp")
    #expect(SpeechEngineFallbackReason.serviceFailed.rawValue == "service_failed")
    let decoded = try JSONDecoder().decode(
      SpeechEngineUsage.self, from: JSONEncoder().encode(SpeechEngineUsage.apple))
    #expect(decoded == .apple)
  }
}
