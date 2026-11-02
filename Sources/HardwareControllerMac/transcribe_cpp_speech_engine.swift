import Foundation
import HardwareControllerASRProtocol

/// One validated Model package installed for the transcribe.cpp engine.
public struct InstalledASRModelPackage: Codable, Equatable, Sendable {
  public let rootURL: URL
  public let packageID: String
  public let version: String
  public let displayName: String
  public let manifestSHA256: Data

  public init(
    rootURL: URL,
    packageID: String,
    version: String,
    displayName: String,
    manifestSHA256: Data
  ) {
    self.rootURL = rootURL
    self.packageID = packageID
    self.version = version
    self.displayName = displayName
    self.manifestSHA256 = manifestSHA256
  }
}

public enum TranscribeCppEngineFailure: Error, Equatable, Sendable {
  /// The package failed revalidation; the user must reinstall it.
  case packageInvalid
  case noSpeechDetected
  /// A crash, hang, unreachable service, or runtime failure; callers fall back.
  case serviceFailed
  /// Repeated crashes this run; callers fall back until relaunch.
  case disabledUntilRelaunch
}

public struct TranscribeCppEngineStatus: Equatable, Sendable {
  public let crashCount: Int
  public let usesGPU: Bool
  public let isDisabledUntilRelaunch: Bool
}

/// Supervises the ASR service: deadline, crash recovery, and idle unload.
///
/// Follows Handy's engine supervisor. A crash during a Metal decode reloads the
/// service CPU-only; repeated crashes disable the engine for the run; a decode
/// past its deadline kills the service; idle time kills it to return memory.
public actor TranscribeCppSpeechEngine {
  public struct Policy: Sendable {
    public var minimumDeadline: Duration
    public var deadlinePerAudioSecond: Duration
    public var idleTimeout: Duration
    public var crashesBeforeDisable: Int

    public init(
      minimumDeadline: Duration = .seconds(2),
      deadlinePerAudioSecond: Duration = .milliseconds(250),
      idleTimeout: Duration = .seconds(300),
      crashesBeforeDisable: Int = 2
    ) {
      self.minimumDeadline = minimumDeadline
      self.deadlinePerAudioSecond = deadlinePerAudioSecond
      self.idleTimeout = idleTimeout
      self.crashesBeforeDisable = crashesBeforeDisable
    }

    func deadline(forSampleCount count: Int) -> Duration {
      let seconds = Double(count) / Double(ASRAudioSamples.sampleRate)
      return max(minimumDeadline, deadlinePerAudioSecond * seconds)
    }
  }

  private let connection: any ASRServiceConnecting
  private let policy: Policy
  private let clock: any Clock<Duration>
  private var crashCount = 0
  private var usesGPU = true
  private var loadedManifest: Data?
  private var idleGeneration = 0

  public init(
    connection: any ASRServiceConnecting = XPCASRServiceConnection(),
    policy: Policy = Policy(),
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.connection = connection
    self.policy = policy
    self.clock = clock
  }

  public var status: TranscribeCppEngineStatus {
    TranscribeCppEngineStatus(
      crashCount: crashCount,
      usesGPU: usesGPU,
      isDisabledUntilRelaunch: isDisabled
    )
  }

  /// Loads the package ahead of use so the first decode skips validation.
  public func prewarm(_ package: InstalledASRModelPackage) async throws(TranscribeCppEngineFailure)
  {
    try requireEnabled()
    try await ensureLoaded(package)
    scheduleIdleUnload()
  }

  public func transcribe(
    _ samples: [Float],
    package: InstalledASRModelPackage,
    language: String,
    vocabulary: [String]
  ) async throws(TranscribeCppEngineFailure) -> ASRServiceTranscript {
    try requireEnabled()
    idleGeneration += 1
    defer { scheduleIdleUnload() }
    let request = ASRTranscribeRequest(
      language: language,
      vocabulary: vocabulary,
      detectSpeech: true
    )
    // launchd may have stopped an idle service between calls, so one reload is expected.
    for attempt in 0..<2 {
      try await ensureLoaded(package)
      switch await decode(samples, request: request) {
      case .success(let transcript):
        return transcript
      case .failure(.service(.notLoaded)) where attempt == 0:
        loadedManifest = nil
      case .failure(.service(.noSpeechDetected)):
        throw .noSpeechDetected
      case .failure(.service(.packageInvalid)):
        throw .packageInvalid
      case .failure(.interrupted):
        recordCrash()
        throw .serviceFailed
      case .failure:
        throw .serviceFailed
      }
    }
    throw .serviceFailed
  }

  public func shutdown() async {
    idleGeneration += 1
    loadedManifest = nil
    await connection.terminate()
  }

  private var isDisabled: Bool {
    crashCount >= policy.crashesBeforeDisable
  }

  private func requireEnabled() throws(TranscribeCppEngineFailure) {
    if isDisabled {
      throw .disabledUntilRelaunch
    }
  }

  private func ensureLoaded(_ package: InstalledASRModelPackage)
    async throws(TranscribeCppEngineFailure)
  {
    guard loadedManifest != package.manifestSHA256 else {
      return
    }
    do {
      _ = try await connection.load(
        ASRLoadRequest(
          packageRootPath: package.rootURL.path(percentEncoded: false),
          expectedManifestSHA256: package.manifestSHA256,
          useGPU: usesGPU
        )
      )
      loadedManifest = package.manifestSHA256
    } catch .service(.packageInvalid) {
      throw .packageInvalid
    } catch .interrupted {
      recordCrash()
      throw .serviceFailed
    } catch {
      throw .serviceFailed
    }
  }

  /// Races the decode against its deadline; a late decode kills the service.
  private func decode(
    _ samples: [Float],
    request: ASRTranscribeRequest
  ) async -> Result<ASRServiceTranscript, ASRServiceCallFailure> {
    let connection = connection
    let clock = clock
    let deadline = policy.deadline(forSampleCount: samples.count)
    let outcome = await withTaskGroup(of: DecodeOutcome.self) { group in
      group.addTask {
        do throws(ASRServiceCallFailure) {
          return .finished(.success(try await connection.transcribe(request, samples: samples)))
        } catch {
          return .finished(.failure(error))
        }
      }
      group.addTask {
        do {
          try await clock.sleep(for: deadline)
          return .timedOut
        } catch {
          return .cancelled
        }
      }
      var first = DecodeOutcome.cancelled
      while let next = await group.next() {
        guard case .cancelled = next else {
          first = next
          break
        }
      }
      if case .timedOut = first {
        // The decode reply only arrives after the process dies.
        await connection.terminate()
      }
      group.cancelAll()
      return first
    }
    switch outcome {
    case .finished(let result):
      return result
    case .timedOut, .cancelled:
      loadedManifest = nil
      return .failure(.interrupted)
    }
  }

  private enum DecodeOutcome: Sendable {
    case finished(Result<ASRServiceTranscript, ASRServiceCallFailure>)
    case timedOut
    case cancelled
  }

  private func recordCrash() {
    crashCount += 1
    // ggml faults are most often Metal faults; CPU-only is the safe retry.
    usesGPU = false
    loadedManifest = nil
  }

  private func scheduleIdleUnload() {
    idleGeneration += 1
    let generation = idleGeneration
    let clock = clock
    let timeout = policy.idleTimeout
    Task { [weak self] in
      try? await clock.sleep(for: timeout)
      await self?.unloadIfIdle(generation: generation)
    }
  }

  private func unloadIfIdle(generation: Int) async {
    guard generation == idleGeneration, loadedManifest != nil else {
      return
    }
    loadedManifest = nil
    await connection.terminate()
  }
}
