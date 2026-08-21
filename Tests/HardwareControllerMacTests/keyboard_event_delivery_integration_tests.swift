import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct KeyboardEventDeliveryIntegrationTests {
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_EVENT_INTEGRATION"
        ] == "1"
    )
  )
  func controlOptionPReachesTheSessionEventStream() throws {
    try #require(
      AXIsProcessTrusted(),
      "Run the opt-in integration test from an Accessibility-trusted shell."
    )

    let capture = EventCapture()
    let interest =
      (CGEventMask(1) << CGEventType.keyDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyUp.rawValue)
      | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    let userInfo = Unmanaged.passUnretained(capture).toOpaque()
    let pendingTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .tailAppendEventTap,
      options: .listenOnly,
      eventsOfInterest: interest,
      callback: captureEvent,
      userInfo: userInfo
    )
    let tap = try #require(pendingTap)
    let source = try #require(
      CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        tap,
        0
      )
    )

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
    CGEvent.tapEnable(tap: tap, enable: true)
    defer {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFRunLoopRemoveSource(
        CFRunLoopGetCurrent(),
        source,
        .defaultMode
      )
    }

    let poster = CoreGraphicsKeyboardEventPoster()
    let shortcut = KeyboardShortcut(
      keyCode: 35,
      modifiers: [.control, .option]
    )
    for event in KeyboardEventPlan.events(for: shortcut) {
      #expect(poster.post(event))
    }

    let deadline = Date().addingTimeInterval(1)
    while capture.relevantEvents.count < 6, Date() < deadline {
      CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }

    #expect(
      capture.relevantEvents == [
        CapturedKeyboardEvent(
          type: .flagsChanged,
          keyCode: 59,
          modifiers: [.control]
        ),
        CapturedKeyboardEvent(
          type: .flagsChanged,
          keyCode: 58,
          modifiers: [.control, .option]
        ),
        CapturedKeyboardEvent(
          type: .keyDown,
          keyCode: 35,
          modifiers: [.control, .option]
        ),
        CapturedKeyboardEvent(
          type: .keyUp,
          keyCode: 35,
          modifiers: [.control, .option]
        ),
        CapturedKeyboardEvent(
          type: .flagsChanged,
          keyCode: 58,
          modifiers: [.control]
        ),
        CapturedKeyboardEvent(
          type: .flagsChanged,
          keyCode: 59,
          modifiers: []
        ),
      ]
    )
  }
}

private struct CapturedKeyboardEvent: Equatable, Sendable {
  let type: CGEventType
  let keyCode: UInt16
  let modifiers: Set<KeyModifier>
}

private final class EventCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [CapturedKeyboardEvent] = []

  var relevantEvents: [CapturedKeyboardEvent] {
    lock.withLock { events }
  }

  func append(_ event: CGEvent, type: CGEventType) {
    let keyCode = UInt16(
      event.getIntegerValueField(.keyboardEventKeycode)
    )
    guard [35, 58, 59].contains(keyCode) else {
      return
    }

    var modifiers: Set<KeyModifier> = []
    if event.flags.contains(.maskControl) {
      modifiers.insert(.control)
    }
    if event.flags.contains(.maskAlternate) {
      modifiers.insert(.option)
    }

    lock.withLock {
      events.append(
        CapturedKeyboardEvent(
          type: type,
          keyCode: keyCode,
          modifiers: modifiers
        )
      )
    }
  }
}

private func captureEvent(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let capture = Unmanaged<EventCapture>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  capture.append(event, type: type)
  return Unmanaged.passUnretained(event)
}
