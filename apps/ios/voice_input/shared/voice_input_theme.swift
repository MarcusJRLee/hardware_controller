import UIKit

/// Voice Input inherits the repository style: neutral surfaces, system type,
/// and the icon's signal amber reserved for an active recording. The app and
/// the keyboard share this one definition.
public enum VoiceInputTheme {
  public static let signal = UIColor(red: 0.98, green: 0.69, blue: 0.13, alpha: 1)
}
