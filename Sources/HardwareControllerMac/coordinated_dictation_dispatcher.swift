import Foundation

/// Every workflow that owns the shared microphone. Order fixes cancellation order.
public enum DictationWorkflow: CaseIterable, Equatable, Sendable {
  case local
  case localAI
  case askGemini
}

public typealias DictationCommandHandler =
  @Sendable (DictationCommand) async -> Void

public struct CoordinatedDictationDispatchers: Sendable {
  public let local: any DictationCommandDispatching
  public let localAI: any DictationCommandDispatching
  public let askGemini: any DictationCommandDispatching

  public init(
    localHandler: @escaping DictationCommandHandler,
    localAIHandler: @escaping DictationCommandHandler,
    askGeminiHandler: @escaping DictationCommandHandler = { _ in },
    onShutdown: @escaping @Sendable () async -> Void = {}
  ) {
    let coordinator = DictationWorkflowCoordinator(
      handlers: [
        .local: localHandler,
        .localAI: localAIHandler,
        .askGemini: askGeminiHandler,
      ],
      onShutdown: onShutdown
    )
    local = CoordinatedDictationCommandDispatcher(
      workflow: .local,
      coordinator: coordinator
    )
    localAI = CoordinatedDictationCommandDispatcher(
      workflow: .localAI,
      coordinator: coordinator
    )
    askGemini = CoordinatedDictationCommandDispatcher(
      workflow: .askGemini,
      coordinator: coordinator
    )
  }
}

private final class CoordinatedDictationCommandDispatcher:
  DictationCommandDispatching,
  @unchecked Sendable
{
  private let workflow: DictationWorkflow
  private let coordinator: DictationWorkflowCoordinator

  init(
    workflow: DictationWorkflow,
    coordinator: DictationWorkflowCoordinator
  ) {
    self.workflow = workflow
    self.coordinator = coordinator
  }

  func submit(_ command: DictationCommand) -> Bool {
    coordinator.submit(workflow: workflow, command: command)
  }

  func shutdown() {
    coordinator.shutdown()
  }

  func shutdownAndWait() async {
    await coordinator.shutdownAndWait()
  }
}

private final class DictationWorkflowCoordinator:
  @unchecked Sendable
{
  private struct Submission: Sendable {
    let workflow: DictationWorkflow
    let command: DictationCommand
  }

  private let continuation: AsyncStream<Submission>.Continuation
  private let consumer: Task<Void, Never>
  private let lock = NSLock()
  private var stopped = false

  /// One handler per workflow; beginning any workflow first cancels the
  /// others, so exactly one owns the microphone.
  init(
    handlers: [DictationWorkflow: DictationCommandHandler],
    onShutdown: @escaping @Sendable () async -> Void
  ) {
    let handler: @Sendable (DictationWorkflow, DictationCommand) async -> Void = {
      workflow, command in
      await handlers[workflow]?(command)
    }
    let (stream, continuation) = AsyncStream<Submission>.makeStream(
      bufferingPolicy: .unbounded
    )
    self.continuation = continuation
    consumer = Task {
      for await submission in stream {
        if submission.command == .begin {
          for other in DictationWorkflow.allCases where other != submission.workflow {
            await handler(other, .cancel)
          }
        }
        await handler(submission.workflow, submission.command)
      }
      for workflow in DictationWorkflow.allCases {
        await handler(workflow, .cancel)
      }
      await onShutdown()
    }
  }

  func submit(
    workflow: DictationWorkflow,
    command: DictationCommand
  ) -> Bool {
    lock.withLock {
      guard !stopped else {
        return false
      }
      switch continuation.yield(
        Submission(workflow: workflow, command: command)
      ) {
      case .enqueued:
        return true
      case .dropped, .terminated:
        return false
      @unknown default:
        return false
      }
    }
  }

  func shutdown() {
    lock.withLock {
      guard !stopped else {
        return
      }
      stopped = true
      continuation.finish()
    }
  }

  func shutdownAndWait() async {
    shutdown()
    await consumer.value
  }

  deinit {
    consumer.cancel()
  }
}
