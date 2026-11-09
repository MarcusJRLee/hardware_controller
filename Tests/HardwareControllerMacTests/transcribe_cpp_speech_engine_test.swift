import Foundation
import HardwareControllerASRProtocol
import HardwareControllerTestSupport
import Testing

@testable import HardwareControllerMac

struct TranscribeCppSpeechEngineTest {
  private let package = ASRTestFixtures.package
  private let samples = [Float](repeating: 0.1, count: 1_600)

  private func transcribe(_ engine: TranscribeCppSpeechEngine)
    async throws(TranscribeCppEngineFailure) -> String
  {
    try await engine.transcribe(samples, package: package, language: "en", vocabulary: []).text
  }

  /// One load serves many decodes, starting on the GPU.
  @Test
  func loadsOnceThenTranscribes() async throws {
    let connection = FakeASRServiceConnection()
    let engine = ASRTestFixtures.engine(connection)
    #expect(try await transcribe(engine) == "parakeet text")
    #expect(try await transcribe(engine) == "parakeet text")
    #expect(await connection.loads.map(\.useGPU) == [true])
    #expect(await connection.loads.first?.expectedManifestSHA256 == package.manifestSHA256)
  }

  /// A crash reloads CPU-only; a second crash disables the engine until relaunch.
  @Test
  func crashesFallBackToCPUThenDisable() async throws {
    let connection = FakeASRServiceConnection(transcribe: [
      .fail(.interrupted), .fail(.interrupted),
    ])
    let engine = ASRTestFixtures.engine(connection)
    await #expect(throws: TranscribeCppEngineFailure.serviceFailed) { try await transcribe(engine) }
    #expect(
      await engine.status
        == TranscribeCppEngineStatus(crashCount: 1, usesGPU: false, isDisabledUntilRelaunch: false))
    await #expect(throws: TranscribeCppEngineFailure.serviceFailed) { try await transcribe(engine) }
    #expect(await connection.loads.map(\.useGPU) == [true, false])
    await #expect(throws: TranscribeCppEngineFailure.disabledUntilRelaunch) {
      try await transcribe(engine)
    }
    #expect(await connection.transcriptions == 2)
  }

  /// A decode past its deadline kills the service and counts as a crash.
  @Test
  func hungDecodeIsKilledAtTheDeadline() async throws {
    let connection = FakeASRServiceConnection(transcribe: [.hang])
    let clock = ManualClock()
    let engine = ASRTestFixtures.engine(connection, clock: clock)
    let decode = Task { try await transcribe(engine) }
    let deadline = ASRTestFixtures.policy.deadline(forSampleCount: samples.count)

    await clock.waitForSleeper(dueWithin: deadline)
    clock.advance(by: deadline - .nanoseconds(1))
    #expect(await connection.terminations == 0)
    clock.advance(by: .nanoseconds(1))

    await #expect(throws: TranscribeCppEngineFailure.serviceFailed) { try await decode.value }
    #expect(await connection.terminations == 1)
    #expect(await engine.status.usesGPU == false)
  }

  /// A service launchd stopped while idle is reloaded once, transparently.
  @Test
  func reloadsAfterTheServiceForgotTheModel() async throws {
    let connection = FakeASRServiceConnection(transcribe: [.fail(.service(.notLoaded))])
    let engine = ASRTestFixtures.engine(connection)
    #expect(try await transcribe(engine) == "parakeet text")
    #expect(await connection.loads.count == 2)
  }

  @Test
  func typedFailuresPassThrough() async {
    let invalid = ASRTestFixtures.engine(
      FakeASRServiceConnection(load: [.fail(.service(.packageInvalid))]))
    await #expect(throws: TranscribeCppEngineFailure.packageInvalid) {
      try await transcribe(invalid)
    }
    let silent = ASRTestFixtures.engine(
      FakeASRServiceConnection(transcribe: [.fail(.service(.noSpeechDetected))]))
    await #expect(throws: TranscribeCppEngineFailure.noSpeechDetected) {
      try await transcribe(silent)
    }
    let broken = ASRTestFixtures.engine(
      FakeASRServiceConnection(transcribe: [.fail(.service(.inferenceFailed))]))
    await #expect(throws: TranscribeCppEngineFailure.serviceFailed) { try await transcribe(broken) }
    #expect(await broken.status.crashCount == 0)
  }

  /// Idle time kills the service so its model memory returns to the system.
  @Test
  func idleServiceIsTerminated() async throws {
    let connection = FakeASRServiceConnection()
    let clock = ManualClock()
    let engine = ASRTestFixtures.engine(connection, clock: clock)
    _ = try await transcribe(engine)

    await clock.waitForSleeper(dueWithin: ASRTestFixtures.policy.idleTimeout)
    clock.advance(by: ASRTestFixtures.policy.idleTimeout)
    try await waitUntil("the idle unload") { await connection.terminations == 1 }
    _ = try await transcribe(engine)
    #expect(await connection.loads.count == 2)
  }

  @Test
  func deadlineScalesWithAudio() {
    let policy = TranscribeCppSpeechEngine.Policy()
    #expect(policy.deadline(forSampleCount: 16_000) == .seconds(2))
    #expect(policy.deadline(forSampleCount: 16_000 * 60) == .seconds(15))
  }
}
