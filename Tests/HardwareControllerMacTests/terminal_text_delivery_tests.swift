import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct TerminalTextDeliveryTests {
  @Test
  func nativeTerminalShellUsesBufferedKeyboardDelivery() {
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier: "com.apple.Terminal",
      role: kAXTextAreaRole as String,
      roleDescription: "text entry area",
      description: "shell",
      identifier: nil,
      contextLabels: [],
      contextRoles: []
    )

    #expect(
      FocusedTextDeliveryPolicy.isTerminal(metadata)
    )
  }

  @Test
  func cursorTerminalUsesBufferedKeyboardDelivery() {
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier:
        "com.todesktop.230313mzl4w4u92",
      role: kAXTextAreaRole as String,
      roleDescription: "text entry area",
      description: nil,
      identifier: nil,
      contextLabels: ["Terminal", "Panel"],
      contextRoles: ["AXWebArea"]
    )

    #expect(
      FocusedTextDeliveryPolicy.bufferedEventDestination(
        for: metadata
      ) == .capturedProcess
    )
  }

  @Test
  func cursorEditorIsNotMisclassifiedAsATerminal() {
    let metadata = FocusedTextTargetMetadata(
      applicationBundleIdentifier:
        "com.todesktop.230313mzl4w4u92",
      role: kAXTextAreaRole as String,
      roleDescription: "text entry area",
      description: "Code editor",
      identifier: "monaco-editor",
      contextLabels: ["Editor", "hardware_controller"],
      contextRoles: ["AXWebArea"]
    )

    #expect(
      !FocusedTextDeliveryPolicy.isTerminal(metadata)
    )
    #expect(
      FocusedTextDeliveryPolicy.bufferedEventDestination(
        for: metadata
      ) == .focusedForeground
    )
  }

  @Test
  func terminalTextNeverContainsCommandSubmittingControls() {
    #expect(
      BufferedTextSanitizer.sanitize(
        "echo hello\nsecond\tcolumn\r\u{1B}👍🏽"
      ) == "echo hello second column 👍🏽"
    )
  }

  @Test
  func terminalInserterTargetsTheCapturedProcessOnce() {
    let poster = RecordingUnicodeTextPoster()
    let inserter = AdaptiveFocusedTextInserter(
      accessibility: AccessibilitySelectedTextInserter {
        _, _ in false
      },
      eventPoster: poster
    )
    let target = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Terminal",
      deliveryCapability: .bufferedEvent(
        anchor: FocusedTextRange(location: 10, length: 0),
        destination: .capturedProcess
      )
    )

    #expect(
      inserter.insert(
        "echo hello\n\u{1B}world",
        into: target
      )
    )
    #expect(
      poster.events == [
        PostedUnicodeText(
          text: "echo hello world",
          destination: .capturedProcess,
          processIdentifier: 42
        )
      ]
    )
  }

  /// Routes buffered text through the current foreground input path.
  @Test
  func foregroundBufferedInserterUsesForegroundRouting() {
    let poster = RecordingUnicodeTextPoster()
    let inserter = AdaptiveFocusedTextInserter(
      accessibility: AccessibilitySelectedTextInserter {
        _, _ in false
      },
      eventPoster: poster
    )
    let target = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Focused app",
      deliveryCapability: .bufferedEvent(
        anchor: FocusedTextRange(location: 0, length: 0),
        destination: .focusedForeground
      )
    )

    #expect(inserter.insert("hello", into: target))
    #expect(
      poster.events == [
        PostedUnicodeText(
          text: "hello",
          destination: .focusedForeground,
          processIdentifier: 42
        )
      ]
    )
  }

  /// Posts a marker through the real foreground event boundary.
  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_FOREGROUND_EVENT_INTEGRATION"
        ] == "1"
    )
  )
  func postsUnicodeThroughRealForegroundInputPath()
    throws
  {
    let marker = try #require(
      ProcessInfo.processInfo.environment[
        "HC_FOREGROUND_MARKER"
      ]
    )
    #expect(!marker.isEmpty)
    #expect(
      CoreGraphicsUnicodeTextEventPoster().post(
        marker,
        destination: .focusedForeground,
        to: getpid()
      )
    )
  }

  @Test
  func terminalWriterRejectsChangedFocusBeforePosting() {
    let inserter = TerminalRecordingInserter(
      selectedRange: FocusedTextRange(
        location: 10,
        length: 0
      )
    )
    let writer = SafeTranscriptWriter(
      targeter: TerminalFocusTargeter(isFocused: false),
      inserter: inserter,
      maximumUTF16UnitsPerInsertion: 2
    )

    #expect(throws: TranscriptionFailure.focusChanged) {
      try writer.insert(
        "hardware controller",
        into: terminalTarget()
      )
    }
    #expect(inserter.inserted.isEmpty)
  }

  @Test
  func terminalWriterRejectsMovedCaretBeforePosting() {
    let inserter = TerminalRecordingInserter(
      selectedRange: FocusedTextRange(
        location: 11,
        length: 0
      )
    )
    let writer = SafeTranscriptWriter(
      targeter: TerminalFocusTargeter(isFocused: true),
      inserter: inserter
    )

    #expect(throws: TranscriptionFailure.caretChanged) {
      try writer.insert(
        "hardware controller",
        into: terminalTarget()
      )
    }
    #expect(inserter.inserted.isEmpty)
  }

  @Test
  func terminalWriterPostsFinalTextAsOneInsertion() throws {
    let inserter = TerminalRecordingInserter(
      selectedRange: FocusedTextRange(
        location: 10,
        length: 0
      )
    )
    let writer = SafeTranscriptWriter(
      targeter: TerminalFocusTargeter(isFocused: true),
      inserter: inserter,
      maximumUTF16UnitsPerInsertion: 2
    )

    try writer.insert(
      "hardware controller",
      into: terminalTarget()
    )

    #expect(inserter.inserted == ["hardware controller"])
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_TERMINAL_EVENT_INTEGRATION"
        ] == "1"
    )
  )
  func postsUnicodeIntoARealTerminalProcess() throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let rawProcessIdentifier =
        environment["HC_TERMINAL_TARGET_PID"],
      let processIdentifier = pid_t(rawProcessIdentifier),
      let marker = environment["HC_TERMINAL_MARKER"],
      !marker.isEmpty
    else {
      Issue.record(
        "Set HC_TERMINAL_TARGET_PID and HC_TERMINAL_MARKER."
      )
      return
    }

    #expect(
      CoreGraphicsUnicodeTextEventPoster().post(
        marker,
        destination: .capturedProcess,
        to: processIdentifier
      )
    )
  }

  private func terminalTarget() -> FocusedTextTarget {
    FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Terminal",
      deliveryCapability: .bufferedEvent(
        anchor: FocusedTextRange(
          location: 10,
          length: 0
        ),
        destination: .capturedProcess
      )
    )
  }
}

private struct PostedUnicodeText: Equatable, Sendable {
  let text: String
  let destination: BufferedTextEventDestination
  let processIdentifier: pid_t
}

private final class RecordingUnicodeTextPoster:
  UnicodeTextEventPosting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storage: [PostedUnicodeText] = []

  var events: [PostedUnicodeText] {
    lock.withLock { storage }
  }

  func post(
    _ text: String,
    destination: BufferedTextEventDestination,
    to processIdentifier: pid_t
  ) -> Bool {
    lock.withLock {
      storage.append(
        PostedUnicodeText(
          text: text,
          destination: destination,
          processIdentifier: processIdentifier
        )
      )
    }
    return true
  }
}

private struct TerminalFocusTargeter: FocusedTextTargeting {
  let isFocused: Bool

  func capture() throws -> FocusedTextTarget {
    throw TranscriptionFailure.noFocusedTextField
  }

  func isStillFocused(
    _ target: FocusedTextTarget
  ) -> Bool {
    isFocused
  }
}

private final class TerminalRecordingInserter:
  FocusedTextInserting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let range: FocusedTextRange
  private var storage: [String] = []

  init(selectedRange: FocusedTextRange) {
    range = selectedRange
  }

  var inserted: [String] {
    lock.withLock { storage }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool {
    lock.withLock {
      storage.append(text)
    }
    return true
  }

  func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange? {
    range
  }
}
