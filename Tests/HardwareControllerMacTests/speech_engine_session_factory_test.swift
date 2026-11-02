import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct SpeechEngineSessionFactoryTest {
  private func factory(
    _ selection: SpeechEngine,
    package: InstalledASRModelPackage? = ASRTestFixtures.package,
    apple: FakeAppleRecognizer = FakeAppleRecognizer()
  ) -> SpeechEngineSessionFactory {
    SpeechEngineSessionFactory(
      configuration: SpeechEngineConfiguration(selection: selection, package: package),
      apple: apple,
      engine: ASRTestFixtures.engine(FakeASRServiceConnection())
    )
  }

  /// transcribe.cpp without a package refuses rather than quietly using Apple.
  @Test
  func missingPackageRefusesEverySession() async {
    let apple = FakeAppleRecognizer()
    let factory = factory(.transcribeCpp, package: nil, apple: apple)
    await #expect(throws: SpeechRecognitionBackendError.engineSetupRequired) {
      _ = try await factory.makeSession(locale: Locale(identifier: "en_US"))
    }
    await #expect(throws: SpeechRecognitionBackendError.engineSetupRequired) {
      try await factory.prepare(locale: Locale(identifier: "en_US"))
    }
    #expect(await apple.sessions.isEmpty)
    #expect(SpeechEngineConfiguration(selection: .transcribeCpp, package: nil).requiresSetup)
    #expect(!SpeechEngineConfiguration(selection: .apple, package: nil).requiresSetup)
  }

  @Test
  func routesSessionsToTheSelectedEngine() async throws {
    let apple = FakeAppleRecognizer()
    let transcribeCpp = factory(.transcribeCpp, apple: apple)
    let session = try await transcribeCpp.makeSession(locale: Locale(identifier: "en_US"))
    #expect(session is TranscribeCppSpeechRecognitionSession)
    #expect(await apple.sessions.isEmpty)

    await transcribeCpp.configure(SpeechEngineConfiguration(selection: .apple, package: nil))
    _ = try await transcribeCpp.makeSession(locale: Locale(identifier: "en_US"))
    try await transcribeCpp.prepare(locale: Locale(identifier: "en_US"))
    #expect(await apple.sessions.count == 1)
    #expect(await apple.preparations == 1)
  }
}
