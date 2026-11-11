import AVFoundation
import Foundation
import HardwareControllerASRProtocol
import HardwareControllerCore
import HardwareControllerTestSupport

@testable import HardwareControllerMac

/// A scripted ASR service: each call takes the next behavior in order.
actor FakeASRServiceConnection: ASRServiceConnecting {
  enum Behavior: Sendable {
    case succeed
    case fail(ASRServiceCallFailure)
    /// Never replies until `terminate()`, like a hung decode.
    case hang
  }

  private var loadBehaviors: [Behavior]
  private var transcribeBehaviors: [Behavior]
  private var hung: CheckedContinuation<Void, Never>?
  private(set) var loads: [ASRLoadRequest] = []
  private(set) var transcriptions = 0
  private(set) var terminations = 0

  init(load: [Behavior] = [], transcribe: [Behavior] = []) {
    loadBehaviors = load
    transcribeBehaviors = transcribe
  }

  func load(_ request: ASRLoadRequest) async throws(ASRServiceCallFailure) -> ASRLoadedModel {
    loads.append(request)
    try await perform(loadBehaviors.isEmpty ? .succeed : loadBehaviors.removeFirst())
    return ASRLoadedModel(
      manifestSHA256: request.expectedManifestSHA256,
      supportsVocabulary: false,
      supportsSpeechDetection: true,
      usesGPU: request.useGPU
    )
  }

  func transcribe(
    _ request: ASRTranscribeRequest,
    samples: [Float]
  ) async throws(ASRServiceCallFailure) -> ASRServiceTranscript {
    transcriptions += 1
    try await perform(transcribeBehaviors.isEmpty ? .succeed : transcribeBehaviors.removeFirst())
    return ASRServiceTranscript(text: "parakeet text", segments: [])
  }

  func terminate() {
    terminations += 1
    hung?.resume()
    hung = nil
  }

  private func perform(_ behavior: Behavior) async throws(ASRServiceCallFailure) {
    switch behavior {
    case .succeed:
      return
    case .fail(let failure):
      throw failure
    case .hang:
      await withCheckedContinuation { hung = $0 }
      throw .interrupted
    }
  }
}

enum ASRTestFixtures {
  static let package = InstalledASRModelPackage(
    rootURL: URL(filePath: "/tmp/parakeet", directoryHint: .isDirectory),
    packageID: "com.longdevity.asr.parakeet_tdt_v3",
    version: "d8d8c32-q8_0",
    displayName: "Parakeet TDT 0.6B v3",
    manifestSHA256: Data(repeating: 1, count: 32)
  )

  static let policy = TranscribeCppSpeechEngine.Policy()

  /// Deadlines and idle unloads fire only when a test advances `clock`.
  static func engine(
    _ connection: FakeASRServiceConnection,
    clock: ManualClock = ManualClock()
  ) -> TranscribeCppSpeechEngine {
    TranscribeCppSpeechEngine(connection: connection, policy: policy, clock: clock)
  }
}

/// Records what Apple's recognizer was asked to do and answers "apple text".
actor FakeAppleRecognizer: ContextualSpeechRecognitionSessionCreating {
  actor Session: SpeechRecognitionSession {
    nonisolated let updates: AsyncThrowingStream<TranscriptRevision, any Error>
    private let continuation: AsyncThrowingStream<TranscriptRevision, any Error>.Continuation
    private(set) var appendedFrames = 0

    init() {
      (updates, continuation) = AsyncThrowingStream.makeStream()
    }

    func append(_ audio: CapturedAudioBuffer) throws {
      appendedFrames += Int(try audio.makePCMBuffer().frameLength)
    }

    func finish() {
      continuation.yield(.committed("apple text"))
      continuation.finish()
    }

    func cancel() {
      continuation.finish()
    }
  }

  private(set) var sessions: [Session] = []
  private(set) var preparations = 0

  func prepare(locale: Locale) {
    preparations += 1
  }

  func makeSession(locale: Locale) -> any SpeechRecognitionSession {
    makeSession(locale: locale, vocabularyHints: [])
  }

  func makeSession(locale: Locale, vocabularyHints: [String]) -> any SpeechRecognitionSession {
    let session = Session()
    sessions.append(session)
    return session
  }
}

/// One tenth of a second of 48 kHz stereo silence-adjacent audio.
func capturedAudio(frames: Int = 4_800, sampleRate: Double = 48_000, channels: UInt32 = 2) throws
  -> CapturedAudioBuffer
{
  guard
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels),
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
  else {
    throw SpeechRecognitionBackendError.conversionFailed("fixture")
  }
  buffer.frameLength = AVAudioFrameCount(frames)
  for channel in 0..<Int(channels) {
    buffer.floatChannelData?[channel].update(repeating: 0.1, count: frames)
  }
  return try CapturedAudioBuffer(copying: buffer)
}

/// Collects every revision a session publishes.
func revisions(of session: any SpeechRecognitionSession) -> Task<[String], any Error> {
  let updates = session.updates
  return Task {
    var texts: [String] = []
    for try await revision in updates {
      texts.append(revision.displayText)
    }
    return texts
  }
}
