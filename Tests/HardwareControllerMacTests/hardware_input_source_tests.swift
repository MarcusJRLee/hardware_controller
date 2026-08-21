import Testing

@testable import HardwareControllerMac

struct HardwareInputSourceTests {
  @Test
  func exclusiveAccessExplainsContention() {
    #expect(
      HardwareInputStartFailure.exclusiveAccess.recoveryMessage
        .lowercased()
        .contains("another copy")
    )
  }

  @Test
  func permissionFailureNamesMacOSAccess() {
    #expect(
      HardwareInputStartFailure.notPermitted.recoveryMessage
        .contains("macOS denied")
    )
  }

  @Test
  func unknownFailureIncludesDiagnosticCode() {
    #expect(
      HardwareInputStartFailure.system(code: -42).recoveryMessage
        .contains("-42")
    )
  }
}
