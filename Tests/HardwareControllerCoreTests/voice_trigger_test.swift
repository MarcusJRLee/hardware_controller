import Testing

@testable import HardwareControllerCore

struct VoiceTriggerTest {
  @Test
  func settingsRejectUnsafeShortcutAndInvalidTiming() {
    #expect(throws: VoiceTriggerSettingsValidationError.unsafeShortcut) {
      try VoiceTriggerSettings(
        shortcut: KeyboardShortcut(
          keyCode: 49,
          modifiers: [.command]
        )
      ).validate()
    }
    #expect(
      throws:
        VoiceTriggerSettingsValidationError.invalidDoublePressInterval
    ) {
      try VoiceTriggerSettings(
        doublePressIntervalMilliseconds: 149
      ).validate()
    }
    #expect(
      throws:
        VoiceTriggerSettingsValidationError.invalidShortPressMaximum
    ) {
      try VoiceTriggerSettings(
        doublePressIntervalMilliseconds: 350,
        shortPressMaximumMilliseconds: 351
      ).validate()
    }
  }

  @Test
  func holdBeginsImmediatelyAndFinishesOnRelease() throws {
    var trigger = try VoiceTriggerStateMachine(
      settings: .default
    )

    let began = trigger.handle(.pressed(atNanoseconds: ms(0)))
    let finished = trigger.handle(.released(atNanoseconds: ms(300)))

    #expect(began.commands == [.begin])
    #expect(began.isCapturing)
    #expect(finished.commands == [.finish])
    #expect(!finished.isCapturing)
  }

  @Test
  func oneShortPressFinishesAtTheDecisionDeadline() throws {
    var trigger = try VoiceTriggerStateMachine(
      settings: .default
    )

    _ = trigger.handle(.pressed(atNanoseconds: ms(0)))
    let released = trigger.handle(.released(atNanoseconds: ms(50)))
    let early = trigger.handle(.decisionTimedOut(atNanoseconds: ms(399)))
    let finished = trigger.handle(
      .decisionTimedOut(atNanoseconds: ms(400))
    )

    #expect(released.decisionDeadlineNanoseconds == ms(400))
    #expect(early.commands.isEmpty)
    #expect(finished.commands == [.finish])
    #expect(!finished.isCapturing)
  }

  @Test
  func doubleTapLatchesAndTheNextDoubleTapFinishesOnce() throws {
    var trigger = try VoiceTriggerStateMachine(
      settings: VoiceTriggerSettings(
        doublePressIntervalMilliseconds: 350,
        shortPressMaximumMilliseconds: 250
      )
    )

    #expect(trigger.handle(.pressed(atNanoseconds: ms(0))).commands == [.begin])
    #expect(trigger.handle(.released(atNanoseconds: ms(50))).commands.isEmpty)
    #expect(trigger.handle(.pressed(atNanoseconds: ms(100))).commands.isEmpty)
    let latched = trigger.handle(.released(atNanoseconds: ms(150)))

    #expect(latched.commands.isEmpty)
    #expect(latched.isCapturing)
    #expect(latched.isLatched)

    #expect(trigger.handle(.pressed(atNanoseconds: ms(1_000))).commands.isEmpty)
    #expect(trigger.handle(.released(atNanoseconds: ms(1_050))).commands.isEmpty)
    #expect(trigger.handle(.pressed(atNanoseconds: ms(1_100))).commands.isEmpty)
    let finished = trigger.handle(.released(atNanoseconds: ms(1_150)))

    #expect(finished.commands == [.finish])
    #expect(!finished.isCapturing)
    #expect(!finished.isLatched)
  }

  @Test
  func duplicateAndUnmatchedTransitionsAreIgnored() throws {
    var trigger = try VoiceTriggerStateMachine(
      settings: .default
    )

    #expect(trigger.handle(.released(atNanoseconds: ms(0))).commands.isEmpty)
    #expect(trigger.handle(.pressed(atNanoseconds: ms(10))).commands == [.begin])
    #expect(trigger.handle(.pressed(atNanoseconds: ms(20))).commands.isEmpty)
    #expect(trigger.handle(.released(atNanoseconds: ms(310))).commands == [.finish])
    #expect(trigger.handle(.released(atNanoseconds: ms(320))).commands.isEmpty)
  }

  @Test
  func interruptionWhileLatchedCancelsExactlyOnce() throws {
    var trigger = try VoiceTriggerStateMachine(
      settings: .default
    )
    _ = trigger.handle(.pressed(atNanoseconds: ms(0)))
    _ = trigger.handle(.released(atNanoseconds: ms(50)))
    _ = trigger.handle(.pressed(atNanoseconds: ms(100)))
    _ = trigger.handle(.released(atNanoseconds: ms(150)))

    let cancelled = trigger.handle(.interrupted)
    let duplicate = trigger.handle(.interrupted)

    #expect(cancelled.commands == [.cancel])
    #expect(!cancelled.isCapturing)
    #expect(duplicate.commands.isEmpty)
  }

  private func ms(_ value: UInt64) -> UInt64 {
    value * 1_000_000
  }
}
