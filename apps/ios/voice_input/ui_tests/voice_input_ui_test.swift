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
    XCTAssertTrue(app.descendants(matching: .any)["capture_style"].exists)
    XCTAssertTrue(
      app.descendants(matching: .any)["system_capture_guidance"].exists
    )
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
  func testSystemCaptureGuidanceAndShortcutsAreReachable() {
    let app = XCUIApplication()
    app.launch()

    let guidance = app.descendants(matching: .any)["system_capture_guidance"]
    for _ in 0..<8 where !guidance.isHittable {
      app.swipeUp()
    }

    XCTAssertTrue(guidance.isHittable)
    let shortcuts = app.buttons["open_voice_shortcuts"]
    XCTAssertTrue(shortcuts.isHittable)
    XCTAssertEqual(shortcuts.label, "Voice Input shortcuts")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "system_capture_guidance"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testStyleMenuIsReachableAndExposesEveryCanonicalStyle() {
    let app = XCUIApplication()
    app.launch()

    let style = app.descendants(matching: .any)["capture_style"]
    for _ in 0..<6 where !style.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(style.isHittable)
    style.tap()
    for label in ["Natural", "Casual", "Formal", "Technical", "Verbatim"] {
      XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 2))
    }

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "style_menu"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testHistoryStorageExposesConfigurableLocalCaps() {
    let app = XCUIApplication()
    app.launch()

    let storage = app.buttons["history_storage"]
    for _ in 0..<8 where !storage.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(storage.isHittable)
    storage.tap()

    for identifier in [
      "history_retention_age",
      "history_retention_size",
      "history_retention_count",
    ] {
      XCTAssertTrue(
        app.descendants(matching: .any)[identifier]
          .waitForExistence(timeout: 2)
      )
    }
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
