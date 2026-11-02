import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct TranscribeCppSpeechRecognitionSessionTest {
  private final class Announcements: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [SpeechEngineFallbackReason] = []
    var all: [SpeechEngineFallbackReason] { lock.withLock { reasons } }
    func record(_ reason: SpeechEngineFallbackReason) { lock.withLock { reasons.append(reason) } }
  }

  private func makeSession(
    _ connection: FakeASRServiceConnection,
    apple: FakeAppleRecognizer,
    announcements: Announcements
  ) throws -> TranscribeCppSpeechRecognitionSession {
    try TranscribeCppSpeechRecognitionSession(
      engine: ASRTestFixtures.engine(connection),
      package: ASRTestFixtures.package,
      locale: Locale(identifier: "en_US"),
      vocabularyHints: [],
      fallback: apple,
      onFallback: announcements.record
    )
  }

  /// The whole recording is decoded once on finish and published as committed text.
  @Test
  func publishesTranscribeCppText() async throws {
    let apple = FakeAppleRecognizer()
    let announcements = Announcements()
    let session = try makeSession(
      FakeASRServiceConnection(), apple: apple, announcements: announcements)
    let texts = revisions(of: session)
    try await session.append(capturedAudio())
    try await session.finish()
    #expect(try await texts.value == ["parakeet text"])
    #expect(await session.engineUsage.engine == .transcribeCpp)
    #expect(await session.engineUsage.modelPackageID == ASRTestFixtures.package.packageID)
    #expect(await apple.sessions.isEmpty)
    #expect(announcements.all.isEmpty)
  }

  /// A service failure sends the same audio to Apple, announced and recorded.
  @Test
  func serviceFailureFallsBackToAppleWithTheSameAudio() async throws {
    let apple = FakeAppleRecognizer()
    let announcements = Announcements()
    let session = try makeSession(
      FakeASRServiceConnection(transcribe: [.fail(.interrupted)]),
      apple: apple,
      announcements: announcements
    )
    let texts = revisions(of: session)
    try await session.append(capturedAudio())
    try await session.append(capturedAudio())
    try await session.finish()
    #expect(try await texts.value == ["apple text"])
    #expect(announcements.all == [.serviceFailed])
    #expect(
      await session.engineUsage == SpeechEngineUsage(engine: .apple, fallbackReason: .serviceFailed)
    )
    let fallback = try #require(await apple.sessions.first)
    // Two 0.1 s buffers at 48 kHz become 0.2 s at 16 kHz once the resampler drains.
    #expect(abs(await fallback.appendedFrames - 3_200) <= 16)
  }

  /// A package that fails revalidation stops with setup required, not Apple.
  @Test
  func invalidPackageRequiresSetup() async throws {
    let apple = FakeAppleRecognizer()
    let session = try makeSession(
      FakeASRServiceConnection(load: [.fail(.service(.packageInvalid))]),
      apple: apple,
      announcements: Announcements()
    )
    let texts = revisions(of: session)
    try await session.append(capturedAudio())
    await #expect(throws: SpeechRecognitionBackendError.engineSetupRequired) {
      try await session.finish()
    }
    await #expect(throws: SpeechRecognitionBackendError.engineSetupRequired) {
      _ = try await texts.value
    }
    #expect(await apple.sessions.isEmpty)
  }

  @Test
  func silenceAndEmptyRecordingsPublishNothing() async throws {
    let silent = try makeSession(
      FakeASRServiceConnection(transcribe: [.fail(.service(.noSpeechDetected))]),
      apple: FakeAppleRecognizer(),
      announcements: Announcements()
    )
    let silentTexts = revisions(of: silent)
    try await silent.append(capturedAudio())
    try await silent.finish()
    #expect(try await silentTexts.value.isEmpty)

    let empty = try makeSession(
      FakeASRServiceConnection(), apple: FakeAppleRecognizer(), announcements: Announcements())
    let emptyTexts = revisions(of: empty)
    try await empty.finish()
    #expect(try await emptyTexts.value.isEmpty)
  }

  @Test
  func cancelEndsTheSessionAndRejectsAudio() async throws {
    let session = try makeSession(
      FakeASRServiceConnection(), apple: FakeAppleRecognizer(), announcements: Announcements())
    let texts = revisions(of: session)
    await session.cancel()
    #expect(try await texts.value.isEmpty)
    await #expect(throws: SpeechRecognitionBackendError.unavailable) {
      try await session.append(capturedAudio())
    }
  }

  @Test
  func mapsLocalesToRuntimeLanguages() {
    #expect(
      TranscribeCppSpeechRecognitionSession.runtimeLanguage(for: Locale(identifier: "en_US"))
        == "en")
    #expect(
      TranscribeCppSpeechRecognitionSession.runtimeLanguage(for: Locale(identifier: "de")) == "de")
  }
}
