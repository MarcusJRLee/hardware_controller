import HardwareControllerCore

/// Converts one exact global Voice chord into serialized Local AI commands.
public actor VoiceKeyboardTriggerController {
  private var trigger: VoiceTriggerStateMachine
  private let dispatcher: any DictationCommandDispatching
  private var deadlineTask: Task<Void, Never>?
  private var deadlineGeneration: UInt64 = 0

  public init(
    settings: VoiceTriggerSettings,
    dispatcher: any DictationCommandDispatching
  ) throws {
    trigger = try VoiceTriggerStateMachine(settings: settings)
    self.dispatcher = dispatcher
  }

  /// Applies one repeat-filtered exact-hot-key transition.
  public func handle(
    phase: ControlPhase,
    timestampNanoseconds: UInt64
  ) {
    let event: VoiceTriggerEvent =
      switch phase {
      case .pressed:
        .pressed(atNanoseconds: timestampNanoseconds)
      case .released:
        .released(atNanoseconds: timestampNanoseconds)
      }
    apply(event)
  }

  /// Cancels any active capture and pending latch decision exactly once.
  public func interrupt() {
    apply(.interrupted)
  }

  /// Exposes the scheduled transition for deterministic boundary tests.
  func decisionTimedOut(atNanoseconds timestampNanoseconds: UInt64) {
    apply(.decisionTimedOut(atNanoseconds: timestampNanoseconds))
  }

  private func apply(_ event: VoiceTriggerEvent) {
    let output = trigger.handle(event)
    let accepted = output.commands.allSatisfy { command in
      dispatcher.submit(command.dictationCommand)
    }
    if !accepted {
      _ = trigger.handle(.interrupted)
      cancelDeadline()
      return
    }
    schedule(deadlineNanoseconds: output.decisionDeadlineNanoseconds)
  }

  private func schedule(deadlineNanoseconds: UInt64?) {
    cancelDeadline()
    guard let deadlineNanoseconds else {
      return
    }
    deadlineGeneration &+= 1
    let generation = deadlineGeneration
    let now = MonotonicClock.nowNanoseconds()
    let delay =
      deadlineNanoseconds > now
      ? deadlineNanoseconds - now : 0
    deadlineTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      await self?.fireDeadline(
        deadlineNanoseconds,
        generation: generation
      )
    }
  }

  private func fireDeadline(
    _ deadlineNanoseconds: UInt64,
    generation: UInt64
  ) {
    guard generation == deadlineGeneration else {
      return
    }
    deadlineTask = nil
    apply(.decisionTimedOut(atNanoseconds: deadlineNanoseconds))
  }

  private func cancelDeadline() {
    deadlineGeneration &+= 1
    deadlineTask?.cancel()
    deadlineTask = nil
  }
}

extension VoiceTriggerCommand {
  fileprivate var dictationCommand: DictationCommand {
    switch self {
    case .begin:
      .begin
    case .finish:
      .finish
    case .cancel:
      .cancel
    }
  }
}
