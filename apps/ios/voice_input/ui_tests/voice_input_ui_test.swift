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

  @MainActor
  func testSettingsShowTheVerifiedModelSetupAndStorage() throws {
    let app = try launch(reset: true, fixture: false)

    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["active_asr_model"].waitForExistence(timeout: Self.timeout)
    )
    XCTAssertTrue(app.staticTexts["Whisper Tiny English"].exists)
    XCTAssertTrue(app.buttons["import_model_package"].exists)
    for label in ["Keep audio for", "Audio up to", "Recordings"] {
      // A Form menu Picker is exposed as a button labeled "<title>, <value>".
      let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label))
        .firstMatch
      for _ in 0..<6 where !picker.isHittable {
        app.swipeUp()
      }
      XCTAssertTrue(picker.isHittable, label)
    }
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
    XCTAssertEqual(style.value as? String, "Formal")
    style.tap()
    app.buttons["Natural"].tap()
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
