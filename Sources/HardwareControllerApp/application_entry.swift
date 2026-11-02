import Foundation
import HardwareControllerMac

/// Runs a diagnostic command, or the app.
///
/// `--verify-speech-engine PACKAGE AUDIO` must run from the installed bundle,
/// because launchd resolves the XPC service only inside its containing app.
@main
enum ApplicationEntry {
  static func main() {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--verify-speech-engine") else {
      HardwareControllerApp.main()
      return
    }
    guard arguments.count > flag + 2 else {
      FileHandle.standardError.write(Data("Usage: --verify-speech-engine PACKAGE AUDIO\n".utf8))
      exit(2)
    }
    let package = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
    let audio = URL(filePath: arguments[flag + 2])
    Task {
      let report = await SpeechEngineSelfCheck.run(packageURL: package, audioURL: audio)
      print(report.lines.joined(separator: "\n"))
      exit(report.passed ? 0 : 1)
    }
    dispatchMain()
  }
}
