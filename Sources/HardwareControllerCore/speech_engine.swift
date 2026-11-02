/// The recognizer that turns Voice audio into text.
public enum SpeechEngine: String, Codable, CaseIterable, Sendable {
  /// transcribe.cpp in the app-embedded ASR service; the default.
  case transcribeCpp = "transcribe_cpp"
  /// Apple's on-device recognizer; used only when chosen or as a fallback.
  case apple
}

/// Why a session used Apple although transcribe.cpp was selected.
public enum SpeechEngineFallbackReason: String, Codable, Sendable {
  /// The service crashed, hung, or failed during this session.
  case serviceFailed = "service_failed"
  /// Repeated crashes disabled the service until the app relaunches.
  case disabledUntilRelaunch = "disabled_until_relaunch"
}

/// Which engine and Model package produced one session's text.
public struct SpeechEngineUsage: Codable, Equatable, Sendable {
  public let engine: SpeechEngine
  public let modelPackageID: String?
  public let modelPackageVersion: String?
  public let modelDisplayName: String?
  public let fallbackReason: SpeechEngineFallbackReason?

  public init(
    engine: SpeechEngine,
    modelPackageID: String? = nil,
    modelPackageVersion: String? = nil,
    modelDisplayName: String? = nil,
    fallbackReason: SpeechEngineFallbackReason? = nil
  ) {
    self.engine = engine
    self.modelPackageID = modelPackageID
    self.modelPackageVersion = modelPackageVersion
    self.modelDisplayName = modelDisplayName
    self.fallbackReason = fallbackReason
  }

  /// Names the engine, its package, and any fallback for History evidence.
  public var title: String {
    switch (engine, fallbackReason) {
    case (.transcribeCpp, _):
      [modelDisplayName ?? "transcribe.cpp", modelPackageVersion].compactMap { $0 }.joined(
        separator: " · ")
    case (.apple, .serviceFailed?):
      "Apple (speech service stopped)"
    case (.apple, .disabledUntilRelaunch?):
      "Apple (speech service paused until relaunch)"
    case (.apple, nil):
      "Apple"
    }
  }

  public static let apple = SpeechEngineUsage(engine: .apple)
}
