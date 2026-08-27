import XCTest

final class VoiceInputUITest: XCTestCase {
  @MainActor
  func testColdLaunchExplainsLocalOnboardingAndKeyboardBoundary() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Voice Input"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["start_capture"].exists)
    XCTAssertTrue(app.staticTexts["Voice anywhere. Private by default."].exists)
    XCTAssertTrue(app.staticTexts["Local processing"].exists)
    XCTAssertTrue(app.staticTexts["Voice Keyboard"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["onboarding_card"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["local_model_library"].exists)
    XCTAssertTrue(app.buttons["import_model_package"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["capture_status"].exists)
    let history = app.descendants(matching: .any)["voice_history"]
    let search = app.textFields["history_search"]
    for _ in 0..<6 where !search.exists {
      app.swipeUp()
    }
    XCTAssertTrue(history.waitForExistence(timeout: 2))
    XCTAssertTrue(search.waitForExistence(timeout: 2))
  }

  @MainActor
  func testLocalCaptureRequiresASelectedModelBeforeRecording() {
    let app = XCUIApplication()
    app.launch()

    let start = app.buttons["start_capture"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()

    let captureStatus = app.descendants(matching: .any)["capture_status"]
    let failed = NSPredicate(format: "value == 'Failed'")
    expectation(for: failed, evaluatedWith: captureStatus)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(app.staticTexts["capture_error"].exists)
    XCTAssertFalse(app.buttons["stop_capture"].exists)
  }

  @MainActor
  func testLargeTextKeepsCaptureControlReachable() {
    let app = XCUIApplication()
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
    ]
    app.launch()

    let start = app.buttons["start_capture"]
    for _ in 0..<6 where !start.isHittable {
      app.swipeUp()
    }

    XCTAssertTrue(start.isHittable)
  }
}
