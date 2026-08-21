import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HardwareControllerApp

@MainActor
struct HardwareControllerAppTests {
  /// Keeps app content below a distinct native title bar.
  @Test
  func applicationWindowUsesNativeTitleBar() {
    let window = NSWindow()

    configureApplicationWindow(window)

    #expect(window.styleMask.contains(.titled))
    #expect(!window.styleMask.contains(.fullSizeContentView))
    #expect(window.titleVisibility == .hidden)
    #expect(!window.titlebarAppearsTransparent)
    #expect(window.titlebarSeparatorStyle == .line)
    #expect(
      window.contentMinSize
        == NSSize(width: 1_000, height: 660)
    )
  }

  /// Keeps the native title synchronized after repeated destination changes.
  @Test
  func applicationWindowTitleFollowsNavigation() async throws {
    let model = AppModel(arguments: ["HardwareController", "--demo"])
    let navigation = ApplicationNavigationModel()
    let preferences = ApplicationPreferencesModel(
      arguments: [],
      isDemoMode: true,
      appearanceApplier: FakeApplicationAppearanceApplier()
    )
    let hostingController = NSHostingController(
      rootView: ApplicationShellView(
        model: model,
        navigation: navigation,
        preferencesModel: preferences
      )
    )
    let window = NSWindow(contentViewController: hostingController)
    configureApplicationWindow(window)
    window.orderFront(nil)
    defer { window.close() }

    try await waitUntil { window.title == "Hardware Controller" }
    navigation.select(.profiles)
    try await waitUntil { window.title == "Profiles" }
    navigation.select(.controller)
    try await waitUntil { window.title == "Controller" }
  }

  /// Forwards workspace sleep and wake notifications exactly once.
  @Test
  func workspaceLifecycleForwardsSleepAndWake() async throws {
    let application = FakeApplicationLifecycle()
    let notificationCenter = NotificationCenter()
    let coordinator = WorkspaceLifecycleCoordinator(
      application: application,
      notificationCenter: notificationCenter
    )
    coordinator.start()
    coordinator.start()

    notificationCenter.post(
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    try await waitUntil {
      application.sleepCount == 1
    }
    notificationCenter.post(
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    #expect(application.sleepCount == 1)
    #expect(application.wakeCount == 1)
    coordinator.stop()
  }

  /// Stops forwarding after observation ends.
  @Test
  func stoppedWorkspaceLifecycleIgnoresNotifications() async throws {
    let application = FakeApplicationLifecycle()
    let notificationCenter = NotificationCenter()
    let coordinator = WorkspaceLifecycleCoordinator(
      application: application,
      notificationCenter: notificationCenter
    )
    coordinator.start()
    coordinator.stop()

    notificationCenter.post(
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    notificationCenter.post(
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    try await Task.sleep(for: .milliseconds(10))

    #expect(application.sleepCount == 0)
    #expect(application.wakeCount == 0)
  }
}

@MainActor
private final class FakeApplicationAppearanceApplier:
  ApplicationAppearanceApplying
{
  /// Accepts appearance changes without mutating the shared application.
  func apply(_ appearance: ApplicationAppearance) {}
}

@MainActor
private final class FakeApplicationLifecycle:
  ApplicationLifecycleHandling
{
  private(set) var sleepCount = 0
  private(set) var wakeCount = 0

  /// Records one forwarded sleep notification.
  func prepareForSleep() async {
    sleepCount += 1
  }

  /// Records one forwarded wake notification.
  func resumeAfterWake() {
    wakeCount += 1
  }
}

@MainActor
/// Waits for one asynchronously forwarded workspace event.
private func waitUntil(
  timeout: Duration = .seconds(1),
  _ condition: @escaping @MainActor () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for the workspace lifecycle event.")
}
