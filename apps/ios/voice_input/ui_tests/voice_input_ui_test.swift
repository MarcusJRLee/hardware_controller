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
    XCTAssertTrue(app.descendants(matching: .any)["capture_status"].exists)
  }

  @MainActor
  func testLocalCaptureReachesAReadyHandoff() {
    let app = XCUIApplication()
    addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
      for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
        alert.buttons[label].tap()
        return true
      }
      return false
    }
    app.launch()

    let start = app.buttons["start_capture"]
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()

    let stop = app.buttons["stop_capture"]
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    stop.tap()

    let captureStatus = app.descendants(matching: .any)["capture_status"]
    let ready = NSPredicate(format: "value == 'Ready'")
    expectation(for: ready, evaluatedWith: captureStatus)
    waitForExpectations(timeout: 5)
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
