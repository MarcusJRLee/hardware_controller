@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import HardwareControllerCore

public protocol FocusedTextInserting: Sendable {
  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool

  func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange?

  func select(
    _ range: FocusedTextRange,
    in target: FocusedTextTarget
  ) -> Bool
}

extension FocusedTextInserting {
  public func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange? {
    nil
  }

  public func select(
    _ range: FocusedTextRange,
    in target: FocusedTextTarget
  ) -> Bool {
    false
  }
}

public struct AccessibilitySelectedTextInserter:
  FocusedTextInserting
{
  private let setSelectedText: @Sendable (AXUIElement, String) -> Bool
  private let copySelectedRange: @Sendable (AXUIElement) -> FocusedTextRange?
  private let setSelectedRange: @Sendable (AXUIElement, FocusedTextRange) -> Bool

  public init() {
    setSelectedText = { element, text in
      AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        text as CFString
      ) == .success
    }
    copySelectedRange = { element in
      var value: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(
          element,
          kAXSelectedTextRangeAttribute as CFString,
          &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
      else {
        return nil
      }
      let rangeValue =
        unsafeDowncast(value, to: AXValue.self)
      guard AXValueGetType(rangeValue) == .cfRange else {
        return nil
      }
      var range = CFRange()
      guard
        AXValueGetValue(rangeValue, .cfRange, &range),
        range.location != kCFNotFound,
        range.location >= 0,
        range.length >= 0
      else {
        return nil
      }
      return FocusedTextRange(
        location: range.location,
        length: range.length
      )
    }
    setSelectedRange = { element, range in
      var value = CFRange(
        location: range.location,
        length: range.length
      )
      guard
        let rangeValue = AXValueCreate(.cfRange, &value)
      else {
        return false
      }
      return AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        rangeValue
      ) == .success
    }
  }

  init(
    setSelectedText:
      @escaping @Sendable (AXUIElement, String) -> Bool
  ) {
    self.setSelectedText = setSelectedText
    copySelectedRange = { _ in nil }
    setSelectedRange = { _, _ in false }
  }

  init(
    setSelectedText:
      @escaping @Sendable (AXUIElement, String) -> Bool,
    copySelectedRange:
      @escaping @Sendable (AXUIElement) -> FocusedTextRange?,
    setSelectedRange:
      @escaping @Sendable (
        AXUIElement,
        FocusedTextRange
      ) -> Bool
  ) {
    self.setSelectedText = setSelectedText
    self.copySelectedRange = copySelectedRange
    self.setSelectedRange = setSelectedRange
  }

  public func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool {
    let operation = {
      setSelectedText(target.element, text)
    }
    guard
      target.processIdentifier == getpid(),
      !Thread.isMainThread
    else {
      return operation()
    }
    return DispatchQueue.main.sync(execute: operation)
  }

  public func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange? {
    let operation = {
      copySelectedRange(target.element)
    }
    guard
      target.processIdentifier == getpid(),
      !Thread.isMainThread
    else {
      return operation()
    }
    return DispatchQueue.main.sync(execute: operation)
  }

  public func select(
    _ range: FocusedTextRange,
    in target: FocusedTextTarget
  ) -> Bool {
    let operation = {
      setSelectedRange(target.element, range)
    }
    guard
      target.processIdentifier == getpid(),
      !Thread.isMainThread
    else {
      return operation()
    }
    return DispatchQueue.main.sync(execute: operation)
  }
}

protocol UnicodeTextEventPosting: Sendable {
  func post(
    _ text: String,
    destination: BufferedTextEventDestination,
    to processIdentifier: pid_t
  ) -> Bool
}

struct CoreGraphicsUnicodeTextEventPoster:
  UnicodeTextEventPosting
{
  func post(
    _ text: String,
    destination: BufferedTextEventDestination,
    to processIdentifier: pid_t
  ) -> Bool {
    guard
      let source = CGEventSource(stateID: .hidSystemState),
      let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 0,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 0,
        keyDown: false
      )
    else {
      return false
    }

    let units = Array(text.utf16)
    units.withUnsafeBufferPointer { buffer in
      keyDown.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
    }
    switch destination {
    case .capturedProcess:
      keyDown.postToPid(processIdentifier)
      keyUp.postToPid(processIdentifier)
    case .focusedForeground:
      keyDown.post(tap: .cghidEventTap)
      keyUp.post(tap: .cghidEventTap)
    }
    return true
  }
}

enum BufferedTextSanitizer {
  /// Removes controls that could submit or escape from the focused field.
  static func sanitize(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 9, 10, 13:
        if result.last != " " {
          result.append(" ")
        }
      default:
        guard
          !CharacterSet.controlCharacters.contains(scalar)
        else {
          continue
        }
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}

public struct AdaptiveFocusedTextInserter:
  FocusedTextInserting
{
  private let accessibility: AccessibilitySelectedTextInserter
  private let eventPoster: any UnicodeTextEventPosting

  public init() {
    accessibility = AccessibilitySelectedTextInserter()
    eventPoster = CoreGraphicsUnicodeTextEventPoster()
  }

  init(
    accessibility:
      AccessibilitySelectedTextInserter,
    eventPoster:
      any UnicodeTextEventPosting
  ) {
    self.accessibility = accessibility
    self.eventPoster = eventPoster
  }

  public func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) -> Bool {
    guard
      case .bufferedEvent(_, let destination) =
        target.deliveryCapability
    else {
      return accessibility.insert(text, into: target)
    }
    let sanitized = BufferedTextSanitizer.sanitize(text)
    guard !sanitized.isEmpty else {
      return true
    }
    return eventPoster.post(
      sanitized,
      destination: destination,
      to: target.processIdentifier
    )
  }

  public func selectedRange(
    in target: FocusedTextTarget
  ) -> FocusedTextRange? {
    accessibility.selectedRange(in: target)
  }

  public func select(
    _ range: FocusedTextRange,
    in target: FocusedTextTarget
  ) -> Bool {
    accessibility.select(range, in: target)
  }
}

public protocol TranscriptWriting: Sendable {
  func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws

  func replace(
    _ mutation: TranscriptCompositionMutation,
    anchoredAt anchor: FocusedTextRange,
    in target: FocusedTextTarget
  ) throws
}

extension TranscriptWriting {
  public func replace(
    _ mutation: TranscriptCompositionMutation,
    anchoredAt anchor: FocusedTextRange,
    in target: FocusedTextTarget
  ) throws {
    throw TranscriptionFailure.insertionFailed
  }
}

public struct SafeTranscriptWriter<
  Targeter: FocusedTextTargeting,
  Inserter: FocusedTextInserting
>: TranscriptWriting {
  private let targeter: Targeter
  private let inserter: Inserter
  private let maximumUTF16UnitsPerInsertion: Int

  public init(
    targeter: Targeter,
    inserter: Inserter,
    maximumUTF16UnitsPerInsertion: Int = 64
  ) {
    self.targeter = targeter
    self.inserter = inserter
    self.maximumUTF16UnitsPerInsertion =
      max(1, maximumUTF16UnitsPerInsertion)
  }

  public func insert(
    _ text: String,
    into target: FocusedTextTarget
  ) throws {
    if case .bufferedEvent(let anchor, _) =
      target.deliveryCapability
    {
      try validateOwnership(of: target)
      guard inserter.selectedRange(in: target) == anchor else {
        throw TranscriptionFailure.caretChanged
      }
      guard inserter.insert(text, into: target) else {
        throw TranscriptionFailure.insertionFailed
      }
      return
    }

    if target.guardsCapturedCaret {
      guard let anchor = target.selectedRange else {
        throw TranscriptionFailure.caretChanged
      }
      var expectedCaret = anchor
      for chunk in Self.chunks(
        text,
        maximumUTF16Units: maximumUTF16UnitsPerInsertion
      ) {
        try validateOwnership(of: target)
        guard inserter.selectedRange(in: target) == expectedCaret else {
          throw TranscriptionFailure.caretChanged
        }
        guard inserter.insert(chunk, into: target) else {
          throw TranscriptionFailure.insertionFailed
        }
        expectedCaret = FocusedTextRange(
          location: expectedCaret.location + chunk.utf16.count,
          length: 0
        )
      }
      return
    }

    for chunk in Self.chunks(
      text,
      maximumUTF16Units: maximumUTF16UnitsPerInsertion
    ) {
      try validateOwnership(of: target)
      guard inserter.insert(chunk, into: target) else {
        throw TranscriptionFailure.insertionFailed
      }
    }
  }

  public func replace(
    _ mutation: TranscriptCompositionMutation,
    anchoredAt anchor: FocusedTextRange,
    in target: FocusedTextTarget
  ) throws {
    try validateOwnership(of: target)

    let expectedCaret = FocusedTextRange(
      location:
        anchor.location + mutation.expectedCaretOffset,
      length: 0
    )
    guard
      inserter.selectedRange(in: target) == expectedCaret
    else {
      throw TranscriptionFailure.caretChanged
    }

    let replacementRange = FocusedTextRange(
      location:
        anchor.location + mutation.replacementOffset,
      length: mutation.replacementLength
    )
    guard
      inserter.select(replacementRange, in: target),
      inserter.insert(mutation.replacementText, into: target)
    else {
      throw TranscriptionFailure.insertionFailed
    }
  }

  private func validateOwnership(
    of target: FocusedTextTarget
  ) throws {
    if let failure = targeter.ownershipFailure(for: target) {
      throw failure.transcriptionFailure
    }
  }

  static func chunks(
    _ text: String,
    maximumUTF16Units: Int
  ) -> [String] {
    guard !text.isEmpty else {
      return []
    }

    var chunks: [String] = []
    var current = ""
    var currentCount = 0
    for character in text {
      let characterText = String(character)
      let characterCount = characterText.utf16.count
      if !current.isEmpty,
        currentCount + characterCount > maximumUTF16Units
      {
        chunks.append(current)
        current = ""
        currentCount = 0
      }
      current.append(character)
      currentCount += characterCount
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }
}
