import XCTest

final class VoiceProbeUITest: XCTestCase {
  @MainActor
  func testColdLaunchExplainsTheHonestKeyboardBoundary() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.navigationBars["Voice Probe"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["start_capture"].exists)
    XCTAssertTrue(app.staticTexts["Enable the keyboard"].exists)
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

    XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 5))
  }
}
