import Foundation
import HardwareControllerMac

/// Runs a diagnostic command, or the app.
///
/// `--verify-speech-engine PACKAGE AUDIO` must run from the installed bundle,
/// because launchd resolves the XPC service only inside its containing app.
/// `--verify-focused-text-delivery PID MARKER` must be launched by
/// LaunchServices, because only then does the bundle's own Accessibility
/// grant apply.
@main
enum ApplicationEntry {
  static func main() {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--verify-speech-engine") {
      guard arguments.count > flag + 2 else {
        usage("--verify-speech-engine PACKAGE AUDIO")
      }
      let package = URL(filePath: arguments[flag + 1], directoryHint: .isDirectory)
      let audio = URL(filePath: arguments[flag + 2])
      runDiagnostic {
        let report = await SpeechEngineSelfCheck.run(packageURL: package, audioURL: audio)
        return (report.lines, report.passed)
      }
    }
    if let flag = arguments.firstIndex(of: "--verify-focused-text-delivery") {
      guard
        arguments.count > flag + 2,
        let target = pid_t(arguments[flag + 1]),
        target > 0,
        !arguments[flag + 2].isEmpty
      else {
        usage("--verify-focused-text-delivery PID MARKER")
      }
      let marker = arguments[flag + 2]
      runDiagnostic {
        let report = await FocusedTextDeliverySelfCheck.run(
          targetProcessIdentifier: target,
          marker: marker
        )
        return (report.lines, report.passed)
      }
    }
    HardwareControllerApp.main()
  }

  private static func usage(_ synopsis: String) -> Never {
    FileHandle.standardError.write(Data("Usage: \(synopsis)\n".utf8))
    exit(2)
  }

  private static func runDiagnostic(
    _ body: @escaping @Sendable () async -> (lines: [String], passed: Bool)
  ) -> Never {
    Task {
      let result = await body()
      print(result.lines.joined(separator: "\n"))
      exit(result.passed ? 0 : 1)
    }
    dispatchMain()
  }
}
