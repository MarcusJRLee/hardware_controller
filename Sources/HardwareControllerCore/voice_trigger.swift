import Foundation

public enum VoiceTriggerSettingsValidationError:
  Error,
  Equatable,
  Sendable
{
  case unsafeShortcut
  case invalidDoublePressInterval
  case invalidShortPressMaximum
}

public struct VoiceTriggerSettings: Codable, Equatable, Sendable {
  public var shortcut: KeyboardShortcut?
  public var doublePressIntervalMilliseconds: UInt16
  public var shortPressMaximumMilliseconds: UInt16

  public init(
    shortcut: KeyboardShortcut? = nil,
    doublePressIntervalMilliseconds: UInt16 = 350,
    shortPressMaximumMilliseconds: UInt16 = 250
  ) {
    self.shortcut = shortcut
    self.doublePressIntervalMilliseconds =
      doublePressIntervalMilliseconds
    self.shortPressMaximumMilliseconds =
      shortPressMaximumMilliseconds
  }

  public static let `default` = VoiceTriggerSettings()

  public func validate() throws {
    if let shortcut, shortcut.modifiers.count < 2 {
      throw VoiceTriggerSettingsValidationError.unsafeShortcut
    }
    guard (150...1_000).contains(doublePressIntervalMilliseconds) else {
      throw VoiceTriggerSettingsValidationError.invalidDoublePressInterval
    }
    guard
      (50...doublePressIntervalMilliseconds)
        .contains(shortPressMaximumMilliseconds)
    else {
      throw VoiceTriggerSettingsValidationError.invalidShortPressMaximum
    }
  }
}

public enum VoiceTriggerEvent: Equatable, Sendable {
  case pressed(atNanoseconds: UInt64)
  case released(atNanoseconds: UInt64)
  case decisionTimedOut(atNanoseconds: UInt64)
  case interrupted
}

public enum VoiceTriggerCommand: Equatable, Sendable {
  case begin
  case finish
  case cancel
}

public struct VoiceTriggerOutput: Equatable, Sendable {
  public let commands: [VoiceTriggerCommand]
  public let decisionDeadlineNanoseconds: UInt64?
  public let isCapturing: Bool
  public let isLatched: Bool
}

public struct VoiceTriggerStateMachine: Sendable {
  private enum State: Equatable, Sendable {
    case idle
    case firstPress(startedAt: UInt64)
    case awaitingLatch(deadline: UInt64)
    case confirmingLatch(startedAt: UInt64)
    case latched
    case firstFinishPress(startedAt: UInt64)
    case awaitingFinish(deadline: UInt64)
    case confirmingFinish(startedAt: UInt64)
  }

  private let doublePressIntervalNanoseconds: UInt64
  private let shortPressMaximumNanoseconds: UInt64
  private var state = State.idle

  public init(settings: VoiceTriggerSettings) throws {
    try settings.validate()
    doublePressIntervalNanoseconds =
      UInt64(settings.doublePressIntervalMilliseconds) * 1_000_000
    shortPressMaximumNanoseconds =
      UInt64(settings.shortPressMaximumMilliseconds) * 1_000_000
  }

  public mutating func handle(
    _ event: VoiceTriggerEvent
  ) -> VoiceTriggerOutput {
    let commands: [VoiceTriggerCommand]
    switch event {
    case .pressed(let timestamp):
      commands = press(at: timestamp)
    case .released(let timestamp):
      commands = release(at: timestamp)
    case .decisionTimedOut(let timestamp):
      commands = timeout(at: timestamp)
    case .interrupted:
      commands = interrupt()
    }
    return output(commands: commands)
  }

  private mutating func press(at timestamp: UInt64)
    -> [VoiceTriggerCommand]
  {
    switch state {
    case .idle:
      state = .firstPress(startedAt: timestamp)
      return [.begin]
    case .firstPress, .confirmingLatch, .firstFinishPress,
      .confirmingFinish:
      return []
    case .awaitingLatch(let deadline):
      guard timestamp <= deadline else {
        state = .firstPress(startedAt: timestamp)
        return [.finish, .begin]
      }
      state = .confirmingLatch(startedAt: timestamp)
      return []
    case .latched:
      state = .firstFinishPress(startedAt: timestamp)
      return []
    case .awaitingFinish(let deadline):
      if timestamp <= deadline {
        state = .confirmingFinish(startedAt: timestamp)
      } else {
        state = .firstFinishPress(startedAt: timestamp)
      }
      return []
    }
  }

  private mutating func release(at timestamp: UInt64)
    -> [VoiceTriggerCommand]
  {
    switch state {
    case .firstPress(let startedAt):
      if isShortPress(startedAt: startedAt, endedAt: timestamp) {
        state = .awaitingLatch(
          deadline: deadline(after: timestamp)
        )
        return []
      }
      state = .idle
      return [.finish]
    case .confirmingLatch(let startedAt):
      guard isShortPress(startedAt: startedAt, endedAt: timestamp) else {
        state = .idle
        return [.finish]
      }
      state = .latched
      return []
    case .firstFinishPress(let startedAt):
      guard isShortPress(startedAt: startedAt, endedAt: timestamp) else {
        state = .latched
        return []
      }
      state = .awaitingFinish(
        deadline: deadline(after: timestamp)
      )
      return []
    case .confirmingFinish(let startedAt):
      guard isShortPress(startedAt: startedAt, endedAt: timestamp) else {
        state = .latched
        return []
      }
      state = .idle
      return [.finish]
    case .idle, .awaitingLatch, .latched, .awaitingFinish:
      return []
    }
  }

  private mutating func timeout(at timestamp: UInt64)
    -> [VoiceTriggerCommand]
  {
    switch state {
    case .awaitingLatch(let deadline) where timestamp >= deadline:
      state = .idle
      return [.finish]
    case .awaitingFinish(let deadline) where timestamp >= deadline:
      state = .latched
      return []
    default:
      return []
    }
  }

  private mutating func interrupt() -> [VoiceTriggerCommand] {
    guard state != .idle else {
      return []
    }
    state = .idle
    return [.cancel]
  }

  private func isShortPress(
    startedAt: UInt64,
    endedAt: UInt64
  ) -> Bool {
    guard endedAt >= startedAt else {
      return false
    }
    return endedAt - startedAt <= shortPressMaximumNanoseconds
  }

  private func deadline(after timestamp: UInt64) -> UInt64 {
    let (deadline, overflow) = timestamp.addingReportingOverflow(
      doublePressIntervalNanoseconds
    )
    return overflow ? .max : deadline
  }

  private func output(
    commands: [VoiceTriggerCommand]
  ) -> VoiceTriggerOutput {
    VoiceTriggerOutput(
      commands: commands,
      decisionDeadlineNanoseconds: decisionDeadline,
      isCapturing: state != .idle,
      isLatched: isLatched
    )
  }

  private var decisionDeadline: UInt64? {
    switch state {
    case .awaitingLatch(let deadline),
      .awaitingFinish(let deadline):
      deadline
    default:
      nil
    }
  }

  private var isLatched: Bool {
    switch state {
    case .latched, .firstFinishPress, .awaitingFinish,
      .confirmingFinish:
      true
    default:
      false
    }
  }
}
