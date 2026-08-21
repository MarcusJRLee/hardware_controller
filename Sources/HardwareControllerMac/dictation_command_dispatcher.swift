import Foundation

public enum DictationCommand: Equatable, Sendable {
  case begin
  case finish
  case cancel
}

public protocol DictationCommandDispatching: Sendable {
  func submit(_ command: DictationCommand) -> Bool
  func shutdown()

  /// Stops accepting commands and waits for serialized cleanup to finish.
  func shutdownAndWait() async
}

extension DictationCommandDispatching {
  public func shutdownAndWait() async {
    shutdown()
  }
}

public struct UnavailableDictationCommandDispatcher:
  DictationCommandDispatching
{
  public init() {}

  public func submit(_ command: DictationCommand) -> Bool {
    false
  }

  public func shutdown() {}
}

public final class AsyncDictationCommandDispatcher:
  DictationCommandDispatching,
  @unchecked Sendable
{
  private let continuation: AsyncStream<DictationCommand>.Continuation
  private let consumer: Task<Void, Never>
  private let lock = NSLock()
  private var stopped = false

  public init(
    handler:
      @escaping @Sendable (DictationCommand) async -> Void,
    onShutdown: @escaping @Sendable () async -> Void = {}
  ) {
    let (stream, continuation) =
      AsyncStream<DictationCommand>.makeStream(
        bufferingPolicy: .unbounded
      )
    self.continuation = continuation
    consumer = Task {
      for await command in stream {
        await handler(command)
      }
      await onShutdown()
    }
  }

  public func submit(_ command: DictationCommand) -> Bool {
    lock.withLock {
      guard !stopped else {
        return false
      }
      switch continuation.yield(command) {
      case .enqueued:
        return true
      case .dropped, .terminated:
        return false
      @unknown default:
        return false
      }
    }
  }

  public func shutdown() {
    lock.withLock {
      guard !stopped else {
        return
      }
      stopped = true
      continuation.yield(.cancel)
      continuation.finish()
    }
  }

  public func shutdownAndWait() async {
    shutdown()
    await consumer.value
  }

  deinit {
    consumer.cancel()
  }
}
