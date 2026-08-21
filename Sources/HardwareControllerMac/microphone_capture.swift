@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import Synchronization

public enum MicrophoneCaptureError: Equatable, Error, Sendable {
  case alreadyRunning
  case noInputDevice
  case inputConfigurationChanged
  case couldNotMonitorInput(String)
  case bufferOverflow
  case invalidBuffer(String)
  case couldNotStart(String)
}

extension MicrophoneCaptureError: LocalizedError {
  /// Preserves the actionable system-boundary detail for presentation.
  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      "Microphone capture is already running."
    case .noInputDevice:
      "No microphone is available."
    case .inputConfigurationChanged:
      "The microphone configuration changed."
    case .couldNotMonitorInput(let detail),
      .invalidBuffer(let detail),
      .couldNotStart(let detail):
      detail
    case .bufferOverflow:
      "Microphone input exceeded the local processing limit."
    }
  }
}

/// Owns immutable PCM bytes while audio crosses concurrency isolation.
public struct CapturedAudioBuffer: Sendable {
  /// Stores PCM format metadata without sharing an AVFoundation object.
  private struct Format: Sendable {
    let sampleRate: Float64
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    /// Copies every scalar from one audio stream description.
    init(copying source: AudioStreamBasicDescription) {
      sampleRate = source.mSampleRate
      formatID = source.mFormatID
      formatFlags = source.mFormatFlags
      bytesPerPacket = source.mBytesPerPacket
      framesPerPacket = source.mFramesPerPacket
      bytesPerFrame = source.mBytesPerFrame
      channelsPerFrame = source.mChannelsPerFrame
      bitsPerChannel = source.mBitsPerChannel
    }

    /// Reconstructs equivalent immutable AVFoundation format metadata.
    func makeAVAudioFormat() throws -> AVAudioFormat {
      var description = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: formatID,
        mFormatFlags: formatFlags,
        mBytesPerPacket: bytesPerPacket,
        mFramesPerPacket: framesPerPacket,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channelsPerFrame,
        mBitsPerChannel: bitsPerChannel,
        mReserved: 0
      )
      guard
        let format = AVAudioFormat(
          streamDescription: &description
        )
      else {
        throw MicrophoneCaptureError.invalidBuffer(
          "The captured audio format is invalid."
        )
      }
      return format
    }
  }

  private struct Plane: Sendable {
    let channelCount: UInt32
    let bytes: Data
  }

  private let format: Format
  private let frameLength: AVAudioFrameCount
  private let planes: [Plane]

  /// Copies every valid byte before the source buffer can be reused.
  public init(copying source: AVAudioPCMBuffer) throws {
    guard source.frameLength > 0 else {
      throw MicrophoneCaptureError.invalidBuffer(
        "The microphone produced an empty audio buffer."
      )
    }

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(
      source.mutableAudioBufferList
    )
    var copiedPlanes: [Plane] = []
    copiedPlanes.reserveCapacity(sourceBuffers.count)

    for sourceBuffer in sourceBuffers {
      guard
        sourceBuffer.mDataByteSize > 0,
        let sourceData = sourceBuffer.mData
      else {
        throw MicrophoneCaptureError.invalidBuffer(
          "The microphone produced audio without sample data."
        )
      }
      copiedPlanes.append(
        Plane(
          channelCount: sourceBuffer.mNumberChannels,
          bytes: Data(
            bytes: sourceData,
            count: Int(sourceBuffer.mDataByteSize)
          )
        )
      )
    }

    guard !copiedPlanes.isEmpty else {
      throw MicrophoneCaptureError.invalidBuffer(
        "The microphone produced no audio planes."
      )
    }

    format = Format(
      copying: source.format.streamDescription.pointee
    )
    frameLength = source.frameLength
    planes = copiedPlanes
  }

  /// Reconstructs a mutable buffer for use inside one recognition actor.
  func makePCMBuffer() throws -> AVAudioPCMBuffer {
    let audioFormat = try format.makeAVAudioFormat()
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: audioFormat,
        frameCapacity: frameLength
      )
    else {
      throw MicrophoneCaptureError.invalidBuffer(
        "A recognition audio buffer could not be allocated."
      )
    }
    buffer.frameLength = frameLength

    let destinationBuffers = UnsafeMutableAudioBufferListPointer(
      buffer.mutableAudioBufferList
    )
    guard destinationBuffers.count == planes.count else {
      throw MicrophoneCaptureError.invalidBuffer(
        "The captured audio plane count changed."
      )
    }

    for index in destinationBuffers.indices {
      let plane = planes[index]
      let destination = destinationBuffers[index]
      guard
        destination.mNumberChannels == plane.channelCount,
        plane.bytes.count <= Int(destination.mDataByteSize),
        let destinationData = destination.mData
      else {
        throw MicrophoneCaptureError.invalidBuffer(
          "The captured audio format changed."
        )
      }

      plane.bytes.copyBytes(
        to: destinationData.assumingMemoryBound(to: UInt8.self),
        count: plane.bytes.count
      )
    }

    return buffer
  }
}

public protocol MicrophoneCapturing: Sendable {
  /// Selects one stable microphone UID, or follows the system default with nil.
  func selectInputDevice(uniqueID: String?) async

  /// Validates and prepares audio without starting capture.
  func prepare() async throws

  /// Starts one bounded immutable audio stream.
  func start() async throws
    -> AsyncThrowingStream<CapturedAudioBuffer, any Error>

  /// Stops capture and terminates the active stream.
  func stop() async
}

extension MicrophoneCapturing {
  /// Keeps compatibility captures on their injected input source.
  public func selectInputDevice(uniqueID: String?) async {}

  /// Permits test and compatibility captures without separate preparation.
  public func prepare() async throws {}
}

public actor AVAudioEngineMicrophoneCapture:
  MicrophoneCapturing
{
  private let engine: any AudioEngineControlling
  private var continuation:
    AsyncThrowingStream<
      CapturedAudioBuffer,
      any Error
    >.Continuation?
  private var isRunning = false

  /// Creates a capture backed by the system audio engine.
  public init(preferredInputDeviceUID: String? = nil) {
    engine = ConfigurationAwareAudioEngineBoundary(
      environment: SystemAudioEnvironment(
        preferredDeviceUID: preferredInputDeviceUID
      )
    )
  }

  /// Creates a capture around an injected audio-engine boundary.
  init(engine: any AudioEngineControlling) {
    self.engine = engine
  }

  /// Stops active capture before changing this app's microphone route.
  public func selectInputDevice(uniqueID: String?) async {
    await stop()
    engine.selectInputDevice(uniqueID: uniqueID)
  }

  /// Validates the input format and primes the stopped engine.
  public func prepare() async throws {
    try engine.prepare()
  }

  /// Starts capture and owns one bounded immutable sample stream.
  public func start() async throws
    -> AsyncThrowingStream<CapturedAudioBuffer, any Error>
  {
    guard !isRunning else {
      throw MicrophoneCaptureError.alreadyRunning
    }

    let (stream, continuation) =
      AsyncThrowingStream<
        CapturedAudioBuffer,
        any Error
      >.makeStream(
        bufferingPolicy: .bufferingNewest(32)
      )

    do {
      try engine.startCapture(
        onBuffer: { buffer in
          do {
            let captured = try CapturedAudioBuffer(
              copying: buffer
            )
            switch continuation.yield(captured) {
            case .enqueued:
              break
            case .dropped:
              continuation.finish(
                throwing:
                  MicrophoneCaptureError.bufferOverflow
              )
            case .terminated:
              break
            @unknown default:
              continuation.finish(
                throwing:
                  MicrophoneCaptureError.bufferOverflow
              )
            }
          } catch {
            continuation.finish(throwing: error)
          }
        },
        onConfigurationChange: {
          continuation.finish(
            throwing:
              MicrophoneCaptureError
              .inputConfigurationChanged
          )
        }
      )
    } catch {
      continuation.finish()
      if let captureError = error as? MicrophoneCaptureError {
        throw captureError
      }
      throw MicrophoneCaptureError.couldNotStart(
        error.localizedDescription
      )
    }

    self.continuation = continuation
    isRunning = true
    return stream
  }

  /// Stops engine work and finishes the active stream exactly once.
  public func stop() async {
    guard isRunning else {
      return
    }
    engine.stop()
    continuation?.finish()
    continuation = nil
    isRunning = false
  }
}

/// Converts owned microphone audio into one recognizer-required format.
final class SpeechAudioBufferConverter {
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?

  /// Creates a serialized converter for the recognizer's input format.
  init(targetFormat: AVAudioFormat) {
    self.targetFormat = targetFormat
  }

  /// Reconstructs and converts one immutable captured audio value.
  func convert(
    _ source: CapturedAudioBuffer
  ) throws -> AVAudioPCMBuffer {
    let sourceBuffer = try source.makePCMBuffer()
    if sourceBuffer.format == targetFormat {
      return sourceBuffer
    }

    let converter: AVAudioConverter
    if let current = self.converter,
      current.inputFormat == sourceBuffer.format
    {
      converter = current
    } else {
      guard
        let created = AVAudioConverter(
          from: sourceBuffer.format,
          to: targetFormat
        )
      else {
        throw
          SpeechRecognitionBackendError
          .conversionFailed("Unsupported audio format.")
      }
      self.converter = created
      converter = created
    }

    let ratio =
      targetFormat.sampleRate / sourceBuffer.format.sampleRate
    let capacity = AVAudioFrameCount(
      ceil(Double(sourceBuffer.frameLength) * ratio) + 32
    )
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: capacity
      )
    else {
      throw
        SpeechRecognitionBackendError
        .conversionFailed(
          "Could not allocate a speech audio buffer."
        )
    }

    let inputProvider = OneShotAudioInput(sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      inputProvider.next(status: inputStatus)
    }

    if status == .error || conversionError != nil {
      throw
        SpeechRecognitionBackendError
        .conversionFailed(
          conversionError?.localizedDescription
            ?? "Audio conversion failed."
        )
    }
    return output
  }
}

/// Supplies one actor-owned source buffer to AVAudioConverter exactly once.
private final class OneShotAudioInput: Sendable {
  private let source: AVAudioPCMBuffer
  private let supplied = Mutex(false)

  /// Retains the immutable-in-use source for the conversion call.
  init(_ source: AVAudioPCMBuffer) {
    self.source = source
  }

  /// Returns the source once, then reports temporary exhaustion.
  func next(
    status: UnsafeMutablePointer<
      AVAudioConverterInputStatus
    >
  ) -> AVAudioBuffer? {
    let shouldSupply = supplied.withLock { supplied in
      guard !supplied else {
        return false
      }
      supplied = true
      return true
    }
    guard shouldSupply else {
      status.pointee = .noDataNow
      return nil
    }
    status.pointee = .haveData
    return source
  }
}
