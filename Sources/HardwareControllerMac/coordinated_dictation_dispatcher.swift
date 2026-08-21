import Foundation

public enum DictationWorkflow: Equatable, Sendable {
  case local
  case localAI
}

public struct CoordinatedDictationDispatchers: Sendable {
  public let local: any DictationCommandDispatching
  public let localAI: any DictationCommandDispatching

  public init(
    localHandler: @escaping @Sendable (DictationCommand) async -> Void,
    localAIHandler: @escaping @Sendable (DictationCommand) async -> Void,
    onShutdown: @escaping @Sendable () async -> Void = {}
  ) {
    let coordinator = DictationWorkflowCoordinator(
      localHandler: localHandler,
      localAIHandler: localAIHandler,
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

  init(
    localHandler: @escaping @Sendable (DictationCommand) async -> Void,
    localAIHandler: @escaping @Sendable (DictationCommand) async -> Void,
    onShutdown: @escaping @Sendable () async -> Void
  ) {
    let (stream, continuation) = AsyncStream<Submission>.makeStream(
      bufferingPolicy: .unbounded
    )
    self.continuation = continuation
    consumer = Task {
      for await submission in stream {
        switch submission.command {
        case .begin:
          switch submission.workflow {
          case .local:
            await localAIHandler(.cancel)
            await localHandler(.begin)
          case .localAI:
            await localHandler(.cancel)
            await localAIHandler(.begin)
          }
        case .finish, .cancel:
          switch submission.workflow {
          case .local:
            await localHandler(submission.command)
          case .localAI:
            await localAIHandler(submission.command)
          }
        }
      }
      await localHandler(.cancel)
      await localAIHandler(.cancel)
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
