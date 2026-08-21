@preconcurrency import ApplicationServices
import Foundation
import HardwareControllerCore
import Testing

@testable import HardwareControllerMac

struct TranscriptWriterTests {
  @Test
  func sameProcessInsertionRunsOnTheMainThread() async {
    let recorder = InsertionThreadRecorder()
    let inserter = AccessibilitySelectedTextInserter {
      _, _ in
      recorder.record()
      return true
    }
    let target = FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: getpid(),
      applicationName: "Hardware Controller"
    )

    let inserted = await withCheckedContinuation {
      continuation in
      DispatchQueue.global().async {
        continuation.resume(
          returning: inserter.insert("Hello", into: target)
        )
      }
    }

    #expect(inserted)
    #expect(recorder.wasMainThread == true)
  }

  @Test
  func externalInsertionDoesNotWaitForTheMainThread() async {
    let recorder = InsertionThreadRecorder()
    let inserter = AccessibilitySelectedTextInserter {
      _, _ in
      recorder.record()
      return true
    }
    let target = makeTarget()

    let inserted = await withCheckedContinuation {
      continuation in
      DispatchQueue.global().async {
        continuation.resume(
          returning: inserter.insert("Hello", into: target)
        )
      }
    }

    #expect(inserted)
    #expect(recorder.wasMainThread == false)
  }

  @Test
  func chunksPreserveCharactersAndReassembleExactly() {
    let text = "Hello 👨‍👩‍👧‍👦 — this is local."

    let chunks =
      SafeTranscriptWriter<
        FocusSequenceTargeter,
        RecordingTextInserter
      >.chunks(
        text,
        maximumUTF16Units: 8
      )

    #expect(chunks.joined() == text)
    #expect(chunks.contains("👨‍👩‍👧‍👦"))
  }

  @Test
  func writerRechecksFocusBeforeEveryChunk() throws {
    let targeter = FocusSequenceTargeter(
      results: [true, false]
    )
    let inserter = RecordingTextInserter()
    let writer = SafeTranscriptWriter(
      targeter: targeter,
      inserter: inserter,
      maximumUTF16UnitsPerInsertion: 4
    )
    let target = makeTarget()

    #expect(throws: TranscriptionFailure.focusChanged) {
      try writer.insert("abcdefgh", into: target)
    }
    #expect(inserter.inserted == ["abcd"])
  }

  @Test
  func failedSelectedTextInsertionStopsWriting() throws {
    let targeter = FocusSequenceTargeter(
      results: [true, true]
    )
    let inserter = RecordingTextInserter(
      failureIndex: 1
    )
    let writer = SafeTranscriptWriter(
      targeter: targeter,
      inserter: inserter,
      maximumUTF16UnitsPerInsertion: 4
    )

    #expect(throws: TranscriptionFailure.insertionFailed) {
      try writer.insert("abcdefgh", into: makeTarget())
    }
    #expect(inserter.inserted == ["abcd"])
  }

  @Test
  func liveReplacementChecksCaretAndSelectsOwnedRange()
    throws
  {
    let inserter = RecordingRangeEditor(
      selectedRange: FocusedTextRange(
        location: 15,
        length: 0
      )
    )
    let writer = SafeTranscriptWriter(
      targeter: FocusSequenceTargeter(results: [true]),
      inserter: inserter
    )

    try writer.replace(
      TranscriptCompositionMutation(
        expectedCaretOffset: 5,
        replacementOffset: 0,
        replacementLength: 5,
        replacementText: "Hello world"
      ),
      anchoredAt: FocusedTextRange(
        location: 10,
        length: 0
      ),
      in: makeTarget()
    )

    #expect(
      inserter.selectedRanges
        == [FocusedTextRange(location: 10, length: 5)]
    )
    #expect(inserter.inserted == ["Hello world"])
  }

  @Test
  func movedCaretStopsLiveReplacementBeforeMutation() {
    let inserter = RecordingRangeEditor(
      selectedRange: FocusedTextRange(
        location: 16,
        length: 0
      )
    )
    let writer = SafeTranscriptWriter(
      targeter: FocusSequenceTargeter(results: [true]),
      inserter: inserter
    )

    #expect(throws: TranscriptionFailure.caretChanged) {
      try writer.replace(
        TranscriptCompositionMutation(
          expectedCaretOffset: 5,
          replacementOffset: 0,
          replacementLength: 5,
          replacementText: "Hello world"
        ),
        anchoredAt: FocusedTextRange(
          location: 10,
          length: 0
        ),
        in: makeTarget()
      )
    }
    #expect(inserter.selectedRanges.isEmpty)
    #expect(inserter.inserted.isEmpty)
  }

  @Test(
    .enabled(
      if:
        ProcessInfo.processInfo.environment[
          "HC_RUN_TEXT_INSERTION_INTEGRATION"
        ] == "1"
    )
  )
  func insertsTextIntoTheFocusedRealTextField() throws {
    #expect(
      AccessibilityPermission.isTrusted,
      "Run this opt-in test from an Accessibility-trusted shell."
    )
    if let rawPID =
      ProcessInfo.processInfo.environment[
        "HC_TEXT_TARGET_PID"
      ],
      let processIdentifier = pid_t(rawPID)
    {
      try verifyRealInsertion(
        targeter: try PinnedTargeter(
          processIdentifier: processIdentifier
        )
      )
      return
    }

    let targeter = AccessibilityFocusedTextTargeting()
    try verifyRealInsertion(targeter: targeter)
  }

  private func verifyRealInsertion<
    Targeter: FocusedTextTargeting
  >(
    targeter: Targeter
  ) throws {
    let target = try targeter.capture()
    let writer = SafeTranscriptWriter(
      targeter: targeter,
      inserter: AccessibilitySelectedTextInserter()
    )

    let marker =
      "Hardware Controller local insertion verifies multiple safe chunks without replacing prior text ✓"
    try writer.insert(
      marker,
      into: target
    )

    var value: CFTypeRef?
    #expect(
      AXUIElementCopyAttributeValue(
        target.element,
        kAXValueAttribute as CFString,
        &value
      ) == .success
    )
    #expect((value as? String)?.contains(marker) == true)
  }

  private func makeTarget() -> FocusedTextTarget {
    FocusedTextTarget(
      element: AXUIElementCreateSystemWide(),
      processIdentifier: 42,
      applicationName: "Notes"
    )
  }
}

private final class InsertionThreadRecorder:
  @unchecked Sendable
{
  private let lock = NSLock()
  private var mainThread: Bool?

  var wasMainThread: Bool? {
    lock.withLock { mainThread }
  }

  func record() {
    lock.withLock {
      mainThread = Thread.isMainThread
    }
  }
}

private struct PinnedTargeter: FocusedTextTargeting {
  let target: FocusedTextTarget

  init(processIdentifier: pid_t) throws {
    let application = AXUIElementCreateApplication(
      processIdentifier
    )
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      throw TranscriptionFailure.noFocusedTextField
    }
    target = FocusedTextTarget(
      element: unsafeDowncast(
        value,
        to: AXUIElement.self
      ),
      processIdentifier: processIdentifier,
      applicationName: "Integration target"
    )
  }

  func capture() throws -> FocusedTextTarget {
    target
  }

  func isStillFocused(
    _ target: FocusedTextTarget
  ) -> Bool {
    true
  }
}

private final class FocusSequenceTargeter:
  FocusedTextTargeting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var results: [Bool]

  init(results: [Bool]) {
    self.results = results
  }

  func capture() throws -> FocusedTextTarget {
    throw TranscriptionFailure.noFocusedTextField
  }

  func isStillFocused(
    _ target: FocusedTextTarget
  ) -> Bool {
    lock.withLock {
      results.isEmpty ? false : results.removeFirst()
    }
  }
}

private final class RecordingTextInserter:
  FocusedTextInserting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let failureIndex: Int?
  private var storage: [String] = []

  init(failureIndex: Int? = nil) {
    self.failureIndex = failureIndex
  }

  var inserted: [String] {
    lock.withLock { storage }
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool {
    lock.withLock {
      if storage.count == failureIndex {
        return false
      }
      storage.append(text)
      return true
    }
  }
}

private final class RecordingRangeEditor:
  FocusedTextInserting,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var currentRange: FocusedTextRange
  private var rangeStorage: [FocusedTextRange] = []
  private var textStorage: [String] = []

  init(selectedRange: FocusedTextRange) {
    currentRange = selectedRange
  }

  var selectedRanges: [FocusedTextRange] {
    lock.withLock { rangeStorage }
  }

  var inserted: [String] {
    lock.withLock { textStorage }
  }

  func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange? {
    lock.withLock { currentRange }
  }

  func select(
    _ range: FocusedTextRange,
    in target: FocusedTextTarget
  ) -> Bool {
    lock.withLock {
      currentRange = range
      rangeStorage.append(range)
    }
    return true
  }

  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool {
    lock.withLock {
      currentRange = FocusedTextRange(
        location: currentRange.location + text.utf16.count,
        length: 0
      )
      textStorage.append(text)
    }
    return true
  }
}
