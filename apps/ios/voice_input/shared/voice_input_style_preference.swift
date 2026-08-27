import Foundation

@MainActor
public struct VoiceInputStylePreferenceStore {
  private let userDefaults: UserDefaults
  private let key: String

  public init(
    userDefaults: UserDefaults = .standard,
    key: String
  ) {
    self.userDefaults = userDefaults
    self.key = key
  }

  public func read() -> VoiceInputStyleKind {
    guard
      let rawValue = userDefaults.string(forKey: key),
      let styleKind = VoiceInputStyleKind(rawValue: rawValue)
    else {
      return .natural
    }
    return styleKind
  }

  public func write(_ styleKind: VoiceInputStyleKind) {
    userDefaults.set(styleKind.rawValue, forKey: key)
  }
}
