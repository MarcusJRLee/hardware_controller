import HardwareControllerVoiceCore
import VoiceInputShared

extension VoiceInputStyleKind {
  var domainStyle: VoiceStyle {
    switch self {
    case .natural: .natural
    case .casualMessage: .casualMessage
    case .formal: .formal
    case .technical: .technical
    case .verbatim: .verbatim
    }
  }
}
