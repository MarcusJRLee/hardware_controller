import Foundation
import Testing

@testable import HardwareControllerMac

struct ApplicationInstallationTests {
  private let home = URL(fileURLWithPath: "/Users/test")

  @Test
  func recognizesSystemApplicationsInstallation() {
    let location = ApplicationInstallationLocation(
      bundleURL: URL(
        fileURLWithPath: "/Applications/Hardware Controller.app"
      ),
      homeDirectory: home
    )

    #expect(location == .applications)
    #expect(location.canRegisterLoginItem)
    #expect(!location.requiresInstallation)
  }

  @Test
  func recognizesUserApplicationsInstallation() {
    let location = ApplicationInstallationLocation(
      bundleURL: URL(
        fileURLWithPath:
          "/Users/test/Applications/Hardware Controller.app"
      ),
      homeDirectory: home
    )

    #expect(location == .applications)
  }

  @Test
  func requiresInstallationForMountedDiskImage() {
    let location = ApplicationInstallationLocation(
      bundleURL: URL(
        fileURLWithPath:
          "/Volumes/Hardware Controller/Hardware Controller.app"
      ),
      homeDirectory: home
    )

    #expect(location == .diskImage)
    #expect(location.requiresInstallation)
    #expect(!location.canRegisterLoginItem)
  }

  @Test
  func allowsDevelopmentOutsideApplicationsWithoutLoginItem() {
    let location = ApplicationInstallationLocation(
      bundleURL: URL(
        fileURLWithPath:
          "/workspace/dist/Hardware Controller.app"
      ),
      homeDirectory: home
    )

    #expect(location == .other)
    #expect(!location.requiresInstallation)
    #expect(!location.canRegisterLoginItem)
  }
}
