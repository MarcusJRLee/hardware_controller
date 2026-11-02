#if DEBUG
  import Foundation

  /// Debug-only seams that let UI tests drive the real capture, ASR,
  /// formatting, and History path deterministically. Release builds compile
  /// none of this, so no launch input can replace the microphone there.
  enum VoiceInputUITestHooks {
    static let resetArgument = "-voice_input_reset_state"
    static let audioFixtureEnvironmentKey = "VOICE_INPUT_AUDIO_FIXTURE"

    static func shouldReset(arguments: [String]) -> Bool {
      arguments.contains(resetArgument)
    }

    /// Only an absolute path to an existing file qualifies; anything else
    /// leaves the system microphone in place.
    static func audioFixtureURL(
      environment: [String: String],
      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
      guard
        let path = environment[audioFixtureEnvironmentKey],
        path.hasPrefix("/"),
        fileExists(path)
      else {
        return nil
      }
      return URL(fileURLWithPath: path)
    }
  }

  /// Places a recorded clip where the recorder would write, so everything
  /// after the microphone runs unchanged.
  struct VoiceInputFixtureAudioRecorderFactory: VoiceInputAudioRecorderCreating {
    let fixtureURL: URL

    func makeRecorder(at url: URL) throws -> any VoiceInputAudioRecording {
      try FileManager.default.copyItem(at: fixtureURL, to: url)
      return VoiceInputFixtureAudioRecorder()
    }
  }

  private struct VoiceInputFixtureAudioRecorder: VoiceInputAudioRecording {
    func prepareToRecord() {}

    func record() -> Bool {
      true
    }

    func stop() {}
  }
#endif
