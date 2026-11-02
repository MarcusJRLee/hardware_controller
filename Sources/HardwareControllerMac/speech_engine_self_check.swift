@preconcurrency import AVFoundation
import Foundation
import HardwareControllerASRProtocol
import HardwareControllerVoiceFFI

/// Proves the bundled ASR service works from the installed app.
///
/// `Hardware Controller --verify-speech-engine PACKAGE AUDIO` loads the package
/// through the real XPC service, decodes the audio repeatedly, kills the
/// service mid-decode, and confirms the next decode recovers. It prints one
/// line per measurement and exits non-zero on any failure.
public enum SpeechEngineSelfCheck {
  public struct Report: Sendable {
    public var lines: [String] = []
    public var passed = true

    mutating func record(_ line: String, passed: Bool = true) {
      lines.append("\(passed ? "PASS" : "FAIL") \(line)")
      self.passed = self.passed && passed
    }
  }

  public static func run(
    packageURL: URL,
    audioURL: URL,
    passes: Int = 10
  ) async -> Report {
    let connection = XPCASRServiceConnection()
    var report = Report()
    let manifest: Data
    let samples: [Float]
    do {
      manifest = try RustPortableVoiceValidator().validateModelPackage(
        at: packageURL,
        limits: .standardModelPackage,
        expectedManifestSHA256: nil
      ).manifestSHA256
      samples = try readSamples(audioURL)
    } catch {
      report.record("inputs: \(error)", passed: false)
      return report
    }
    let load = ASRLoadRequest(
      packageRootPath: packageURL.path(percentEncoded: false),
      expectedManifestSHA256: manifest,
      useGPU: true
    )
    let request = ASRTranscribeRequest(language: "en", vocabulary: [], detectSpeech: true)

    let loadStart = ContinuousClock.now
    do {
      _ = try await connection.load(load)
      report.record("load ms=\(milliseconds(since: loadStart))")
    } catch {
      report.record("load: \(error)", passed: false)
      return report
    }

    var roundTrips: [Double] = []
    var overheads: [Double] = []
    var text = ""
    for _ in 0..<passes {
      let start = ContinuousClock.now
      do {
        let transcript = try await connection.transcribe(request, samples: samples)
        let roundTrip = milliseconds(since: start)
        roundTrips.append(roundTrip)
        overheads.append(max(0, roundTrip - transcript.decodeMilliseconds))
        text = transcript.text
      } catch {
        report.record("transcribe: \(error)", passed: false)
        return report
      }
    }
    report.record("text \(text)", passed: !text.isEmpty)
    report.record("round_trip \(summary(roundTrips))")
    let ipc = summary(overheads)
    report.record("ipc \(ipc)", passed: percentile(0.99, overheads) <= 10)

    // A crash mid-decode must surface as an interruption, never a hang.
    let killed = Task { () -> ASRServiceCallFailure? in
      do throws(ASRServiceCallFailure) {
        _ = try await connection.transcribe(request, samples: samples + samples + samples)
        return nil
      } catch {
        return error
      }
    }
    try? await Task.sleep(for: .milliseconds(20))
    await connection.killServiceProcess()
    let failure = await killed.value
    report.record(
      "crash_mid_decode \(failure.map { "\($0)" } ?? "completed before the crash")",
      passed: failure == .interrupted
    )
    do {
      _ = try await connection.load(load)
      let recovered = try await connection.transcribe(request, samples: samples)
      report.record(
        "recovered_after_crash \(recovered.text == text)", passed: recovered.text == text)
    } catch {
      report.record("recovered_after_crash: \(error)", passed: false)
    }
    await connection.terminate()
    return report
  }

  static func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    else {
      throw SpeechRecognitionBackendError.conversionFailed("The audio could not be buffered.")
    }
    try file.read(into: buffer)
    var accumulator = try ASRSampleAccumulator()
    try accumulator.append(buffer)
    try accumulator.flush()
    return accumulator.samples
  }

  static func summary(_ values: [Double]) -> String {
    let format = { (value: Double) in String(format: "%.1f", value) }
    return
      "samples=\(values.count) p50=\(format(percentile(0.5, values))) p95=\(format(percentile(0.95, values)))"
      + " p99=\(format(percentile(0.99, values))) max=\(format(values.max() ?? 0))"
  }

  static func percentile(_ fraction: Double, _ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else {
      return 0
    }
    let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
    return sorted[min(max(rank, 0), sorted.count - 1)]
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1_000_000_000_000_000
  }
}
