import XCTest

final class VoiceInputUITest: XCTestCase {
  /// Shared CI simulators stall for seconds under load; a passing wait returns
  /// as soon as its condition holds, so only failures pay this deadline.
  private static let timeout: TimeInterval = 60
  private static let jfkPhrase = "ask not what your country can do for you"

  override func setUp() {
    continueAfterFailure = false
  }

  /// The whole product path from a fresh install: bundled model provisioning,
  /// capture, transcribe.cpp ASR, formatting, History, and search. Only the
  /// microphone is replaced, by a recorded clip passed through the runner.
  @MainActor
  func testFreshInstallDictatesIntoSearchableHistory() throws {
    let app = try launch(reset: true, fixture: true)

    let start = app.buttons["start_capture"]
    XCTAssertTrue(start.waitForExistence(timeout: Self.timeout))
    wait(for: start, toBe: "isEnabled == true")
    start.tap()
    let stop = app.buttons["stop_capture"]
    XCTAssertTrue(stop.waitForExistence(timeout: Self.timeout))
    stop.tap()

    let result = app.staticTexts["dictation_result"]
    XCTAssertTrue(result.waitForExistence(timeout: Self.timeout))
    XCTAssertTrue(result.label.localizedCaseInsensitiveContains(Self.jfkPhrase), result.label)
    XCTAssertEqual(app.staticTexts["dictation_title"].label, "Done")
    XCTAssertTrue(app.buttons["dictation_copy"].isHittable)
    attachScreenshot(app, named: "dictation_result")

    app.tabBars.buttons["History"].tap()
    let row = app.descendants(matching: .any)["history_row"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
    XCTAssertTrue(row.label.localizedCaseInsensitiveContains("fellow Americans"), row.label)
    XCTAssertFalse(app.staticTexts["history_error"].exists)

    let search = app.searchFields["Search transcripts"]
    search.tap()
    search.typeText("country\n")
    XCTAssertTrue(row.waitForExistence(timeout: Self.timeout))
    row.tap()
    let detail = app.staticTexts["history_text"]
    XCTAssertTrue(detail.waitForExistence(timeout: Self.timeout))
    XCTAssertTrue(detail.label.localizedCaseInsensitiveContains(Self.jfkPhrase))
    XCTAssertTrue(app.buttons["history_copy"].exists)
    attachScreenshot(app, named: "history_detail")
  }

  /// Deleting one dictation and clearing History both reach storage: the
  /// empty state survives a relaunch.
  @MainActor
  func testHistoryDeletesOneDictationThenClearsAll() throws {
    let app = try launch(reset: true, fixture: true)
    for _ in 0..<2 {
      try dictate(in: app)
    }
    app.tabBars.buttons["History"].tap()
    // Each History entry is one list cell; its label and link are not counted.
    let rows = app.collectionViews.cells
    wait(for: rows, toCount: 2)

    rows.firstMatch.swipeLeft()
    app.buttons["history_delete_row"].tap()
    wait(for: rows, toCount: 1)

    app.buttons["history_menu"].tap()
    app.buttons["history_clear_all"].tap()
    // iOS renders the dialog action twice (sheet and accessibility copy).
    app.buttons["history_confirm_clear_all"].firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["history_empty"].waitForExistence(timeout: Self.timeout))

    app.terminate()
    app.launchArguments.removeAll { $0 == "-voice_input_reset_state" }
    app.launch()
    app.tabBars.buttons["History"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["history_empty"].waitForExistence(timeout: Self.timeout))
    XCTAssertEqual(rows.count, 0)
  }

  @MainActor
  func testSettingsShowTheVerifiedModelSetupAndStorage() throws {
    let app = try launch(reset: true, fixture: false)

    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["active_asr_model"].waitForExistence(timeout: Self.timeout)
    )
    XCTAssertTrue(app.staticTexts["Whisper Tiny English"].exists)
    for packageID in ["whisper_base_en", "whisper_small_en", "parakeet_tdt_v3"] {
      XCTAssertTrue(app.buttons["download_model_com.longdevity.asr.\(packageID)"].exists, packageID)
    }
    for label in ["Keep audio for", "Audio up to", "Recordings"] {
      // A Form menu Picker is exposed as a button labeled "<title>, <value>".
      let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label))
        .firstMatch
      for _ in 0..<6 where !picker.isHittable {
        app.swipeUp()
      }
      XCTAssertTrue(picker.isHittable, label)
    }
    let importButton = app.buttons["import_model_package"]
    for _ in 0..<6 where !importButton.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(importButton.isHittable)
    let shortcuts = app.buttons["open_voice_shortcuts"]
    for _ in 0..<6 where !shortcuts.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(shortcuts.isHittable)
    attachScreenshot(app, named: "settings")
  }

  @MainActor
  func testStyleMenuOffersEveryCanonicalStyle() throws {
    let app = try launch(reset: false, fixture: false)

    let style = app.buttons["capture_style"]
    XCTAssertTrue(style.waitForExistence(timeout: Self.timeout))
    style.tap()
    for label in ["Natural", "Casual", "Formal", "Technical", "Verbatim"] {
      XCTAssertTrue(app.buttons[label].waitForExistence(timeout: Self.timeout), label)
    }
    app.buttons["Formal"].tap()
    wait(for: style, toBe: "value == 'Formal'")
    style.tap()
    let natural = app.buttons["Natural"]
    XCTAssertTrue(natural.waitForExistence(timeout: Self.timeout))
    natural.tap()
    wait(for: style, toBe: "value == 'Natural'")
  }

  @MainActor
  func testLargeTextKeepsTheRecordButtonReachable() throws {
    let app = XCUIApplication()
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
    ]
    app.launch()

    let start = app.buttons["start_capture"]
    XCTAssertTrue(start.waitForExistence(timeout: Self.timeout))
    XCTAssertTrue(start.isHittable)
    attachScreenshot(app, named: "large_text")
  }

  @MainActor
  private func launch(reset: Bool, fixture: Bool) throws -> XCUIApplication {
    let app = XCUIApplication()
    if reset {
      app.launchArguments.append("-voice_input_reset_state")
    }
    if fixture {
      // scripts/check_ios.sh passes it as TEST_RUNNER_VOICE_INPUT_AUDIO_FIXTURE.
      let path = try XCTUnwrap(
        ProcessInfo.processInfo.environment["VOICE_INPUT_AUDIO_FIXTURE"],
        "Run through scripts/check_ios.sh, which supplies the recorded clip."
      )
      app.launchEnvironment["VOICE_INPUT_AUDIO_FIXTURE"] = path
    }
    app.launch()
    return app
  }

  @MainActor
  private func dictate(in app: XCUIApplication) throws {
    app.tabBars.buttons["Dictate"].tap()
    let start = app.buttons["start_capture"]
    XCTAssertTrue(start.waitForExistence(timeout: Self.timeout))
    wait(for: start, toBe: "isEnabled == true")
    start.tap()
    let stop = app.buttons["stop_capture"]
    XCTAssertTrue(stop.waitForExistence(timeout: Self.timeout))
    stop.tap()
    let title = app.staticTexts["dictation_title"]
    wait(for: title, toBe: "label == 'Done'")
  }

  @MainActor
  private func wait(for query: XCUIElementQuery, toCount count: Int) {
    expectation(for: NSPredicate(format: "count == %d", count), evaluatedWith: query)
    waitForExpectations(timeout: Self.timeout)
  }

  @MainActor
  private func wait(for element: XCUIElement, toBe predicate: String) {
    expectation(for: NSPredicate(format: predicate), evaluatedWith: element)
    waitForExpectations(timeout: Self.timeout)
  }

  @MainActor
  private func attachScreenshot(_ app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
