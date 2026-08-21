import AppKit
import CoreServices

public enum AppLaunchPresentation {
  public static let activationPolicy: NSApplication.ActivationPolicy = .regular

  public static var isCurrentLaunchFromLoginItem: Bool {
    isLoginItemLaunch(
      appleEvent: NSAppleEventManager.shared().currentAppleEvent
    )
  }

  public static func shouldPresentApplicationWindow(
    arguments: [String],
    isLoginItemLaunch: Bool
  ) -> Bool {
    arguments.contains("--demo")
      || arguments.contains("--show-settings")
      || !isLoginItemLaunch
  }

  public static func isLoginItemLaunch(
    appleEvent: NSAppleEventDescriptor?
  ) -> Bool {
    appleEvent?
      .paramDescriptor(
        forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
      ) != nil
  }
}

/// Keeps AppKit alive until asynchronous process cleanup completes.
@MainActor
public final class AppTerminationCoordinator {
  private var shutdownTask: Task<Void, Never>?

  public init() {}

  /// Starts cleanup once and defers every pending termination request.
  public func requestTermination(
    shutdown:
      @escaping @MainActor @Sendable () async -> Void,
    reply: @escaping @MainActor @Sendable () -> Void
  ) -> NSApplication.TerminateReply {
    guard shutdownTask == nil else {
      return .terminateLater
    }

    shutdownTask = Task { @MainActor in
      await shutdown()
      reply()
    }
    return .terminateLater
  }
}
