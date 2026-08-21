import AppKit
import CoreServices
import Testing

@testable import HardwareControllerMac

struct AppLaunchPresentationTests {
  @Test
  func foregroundAppUsesRegularActivationPolicy() {
    #expect(AppLaunchPresentation.activationPolicy == .regular)
  }

  @Test
  func manualLaunchPresentsSettings() {
    #expect(
      AppLaunchPresentation.shouldPresentApplicationWindow(
        arguments: [],
        isLoginItemLaunch: false
      )
    )
  }

  @Test
  func loginItemLaunchStaysQuiet() {
    #expect(
      !AppLaunchPresentation.shouldPresentApplicationWindow(
        arguments: [],
        isLoginItemLaunch: true
      )
    )
  }

  @Test
  func loginItemAppleEventIsRecognized() {
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAEOpenApplication),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(
      NSAppleEventDescriptor(boolean: true),
      forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
    )

    #expect(
      AppLaunchPresentation.isLoginItemLaunch(appleEvent: event)
    )
    #expect(
      !AppLaunchPresentation.isLoginItemLaunch(appleEvent: nil)
    )
  }

  @Test(arguments: ["--demo", "--show-settings"])
  func explicitPresentationOverridesQuietLaunch(argument: String) {
    #expect(
      AppLaunchPresentation.shouldPresentApplicationWindow(
        arguments: [argument],
        isLoginItemLaunch: true
      )
    )
  }

  @Test
  @MainActor
  func terminationWaitsForShutdownBeforeReplying() async {
    let coordinator = AppTerminationCoordinator()
    let gate = AsyncGate()
    let replyRecorder = TerminationReplyRecorder()
    let (events, continuation) =
      AsyncStream<TerminationEvent>.makeStream()
    var iterator = events.makeAsyncIterator()

    let response = coordinator.requestTermination(
      shutdown: {
        continuation.yield(.shutdownStarted)
        await gate.wait()
      },
      reply: {
        replyRecorder.record()
        continuation.yield(.replied)
      }
    )

    #expect(response == .terminateLater)
    #expect(await iterator.next() == .shutdownStarted)
    #expect(!replyRecorder.didReply)
    await gate.open()
    #expect(await iterator.next() == .replied)
    #expect(replyRecorder.didReply)
    continuation.finish()
  }
}

private enum TerminationEvent: Equatable, Sendable {
  case shutdownStarted
  case replied
}

@MainActor
private final class TerminationReplyRecorder {
  private(set) var didReply = false

  func record() {
    didReply = true
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else {
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let currentWaiters = waiters
    waiters.removeAll()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }
}
