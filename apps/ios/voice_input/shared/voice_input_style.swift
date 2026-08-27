public enum VoiceInputStyleKind:
  String,
  CaseIterable,
  Codable,
  Equatable,
  Hashable,
  Sendable
{
  case natural
  case casualMessage
  case formal
  case technical
  case verbatim

  public var displayName: String {
    switch self {
    case .natural: "Natural"
    case .casualMessage: "Casual"
    case .formal: "Formal"
    case .technical: "Technical"
    case .verbatim: "Verbatim"
    }
  }
}
