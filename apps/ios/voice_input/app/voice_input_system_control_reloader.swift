import VoiceInputShared
import WidgetKit

enum VoiceInputSystemControlReloader {
  static func reload() {
    ControlCenter.shared.reloadControls(
      ofKind: VoiceInputEnvironment.systemCaptureControlKind
    )
  }
}
