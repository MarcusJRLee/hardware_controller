import VoiceInputShared
import XCTest

final class VoiceInputKeyboardLayoutTest: XCTestCase {
  private let layers: [VoiceInputKeyboardLayer] = [.letters, .numbers, .symbols]

  func testEveryRowFillsTheKeyboardWidth() {
    for layer in layers {
      for showsNextKeyboard in [true, false] {
        for row in VoiceInputKeyboardLayout.rows(for: layer, showsNextKeyboard: showsNextKeyboard) {
          let width = row.inset * 2 + row.slots.reduce(0) { $0 + $1.width }
          XCTAssertEqual(width, VoiceInputKeyboardLayout.rowWidth, accuracy: 0.0001, "\(layer)")
        }
      }
    }
  }

  func testLayersOfferLettersNumbersAndSymbols() {
    let letters = characters(.letters)
    XCTAssertEqual(letters.count, 26)
    XCTAssertTrue(characters(.numbers).isSuperset(of: Set("0123456789".map(String.init))))
    XCTAssertTrue(characters(.symbols).isSuperset(of: ["#", "%", "€", "\\"]))
    let bottom = VoiceInputKeyboardLayout.rows(for: .numbers, showsNextKeyboard: false)[3]
    XCTAssertEqual(bottom.slots.map(\.key), [.layer(.letters), .space, .returnKey])
  }

  func testTheGlobeKeyAppearsOnlyWhenTheSystemAsks() {
    let keys = { (shows: Bool) in
      VoiceInputKeyboardLayout.rows(for: .letters, showsNextKeyboard: shows)[3].slots.map(\.key)
    }
    XCTAssertTrue(keys(true).contains(.nextKeyboard))
    XCTAssertFalse(keys(false).contains(.nextKeyboard))
  }

  func testSentenceStartCapitalization() {
    let cases: [(String?, Bool)] = [
      (nil, true), ("", true), ("   ", true), ("Hello. ", true), ("Why? ", true),
      ("Line\n", true), ("Hello", false), ("Hello ", false), ("Hello.", false), ("e.g", false),
    ]
    for (context, expected) in cases {
      XCTAssertEqual(
        VoiceInputKeyboardLayout.shouldCapitalize(after: context), expected, "\(context ?? "nil")")
    }
  }

  func testDoubleSpaceBecomesAPeriodOnlyAfterAWord() {
    XCTAssertTrue(VoiceInputKeyboardLayout.shouldInsertPeriod(after: "Hello "))
    XCTAssertTrue(VoiceInputKeyboardLayout.shouldInsertPeriod(after: "at 5 "))
    for context in [nil, "", " ", "Hello.  ", "Hello", "Hi.  "] as [String?] {
      XCTAssertFalse(
        VoiceInputKeyboardLayout.shouldInsertPeriod(after: context), "\(context ?? "nil")")
    }
  }

  private func characters(_ layer: VoiceInputKeyboardLayer) -> Set<String> {
    Set(
      VoiceInputKeyboardLayout.rows(for: layer, showsNextKeyboard: true)
        .flatMap(\.slots)
        .compactMap { slot in
          if case .character(let character) = slot.key { return character }
          return nil
        })
  }
}
