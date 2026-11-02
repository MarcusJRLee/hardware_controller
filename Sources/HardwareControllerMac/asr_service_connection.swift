import Darwin
import Foundation
import HardwareControllerASRProtocol

public enum ASRServiceCallFailure: Error, Equatable, Sendable {
  /// The service answered with a typed failure.
  case service(ASRServiceFailure)
  /// The service process exited or crashed during the call.
  case interrupted
  /// The service could not be reached at all.
  case unavailable
}

/// The calls the app makes to the ASR service, so supervision tests need no process.
public protocol ASRServiceConnecting: Sendable {
  func load(_ request: ASRLoadRequest) async throws(ASRServiceCallFailure) -> ASRLoadedModel
  func transcribe(
    _ request: ASRTranscribeRequest,
    samples: [Float]
  ) async throws(ASRServiceCallFailure) -> ASRServiceTranscript
  /// Kills the service process so a hang or idle model releases everything.
  func terminate() async
}

/// Talks to the app-embedded XPC service.
public actor XPCASRServiceConnection: ASRServiceConnecting {
  private let serviceName: String
  private var connection: NSXPCConnection?

  public init(serviceName: String = ASRServiceIdentity.serviceName) {
    self.serviceName = serviceName
  }

  public func load(
    _ request: ASRLoadRequest
  ) async throws(ASRServiceCallFailure) -> ASRLoadedModel {
    let reply = try await call { proxy, resume in
      proxy.load(ASRServiceCodec.encode(request), reply: resume)
    }
    return try Self.unwrap(ASRLoadedModel.self, from: reply)
  }

  public func transcribe(
    _ request: ASRTranscribeRequest,
    samples: [Float]
  ) async throws(ASRServiceCallFailure) -> ASRServiceTranscript {
    let audio = ASRAudioSamples.encode(samples)
    let reply = try await call { proxy, resume in
      proxy.transcribe(ASRServiceCodec.encode(request), samples: audio, reply: resume)
    }
    return try Self.unwrap(ASRServiceTranscript.self, from: reply)
  }

  public func terminate() {
    guard let connection else {
      return
    }
    // A hung decode never returns, so invalidating alone would leave the
    // process and its model resident.
    killServiceProcess()
    connection.invalidate()
    self.connection = nil
  }

  /// Kills the service but keeps the connection, exactly as a crash would.
  public func killServiceProcess() {
    // The service runs as this user, so the app may signal it.
    if let processIdentifier = connection?.processIdentifier, processIdentifier > 0 {
      kill(processIdentifier, SIGKILL)
    }
  }

  private func call(
    _ send: @escaping @Sendable (ASRServiceXPCProtocol, @escaping @Sendable (Data) -> Void) -> Void
  ) async throws(ASRServiceCallFailure) -> Data {
    let connection = activeConnection()
    let result: Result<Data, ASRServiceCallFailure> = await withCheckedContinuation {
      continuation in
      let once = ResumeOnce(continuation)
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        let code = (error as NSError).code
        once.resume(.failure(code == NSXPCConnectionInterrupted ? .interrupted : .unavailable))
      }
      guard let service = proxy as? ASRServiceXPCProtocol else {
        once.resume(.failure(.unavailable))
        return
      }
      send(service) { data in once.resume(.success(data)) }
    }
    if case .failure(.unavailable) = result {
      // An invalidated connection never recovers; the next call makes a new one.
      self.connection?.invalidate()
      self.connection = nil
    }
    return try result.get()
  }

  private func activeConnection() -> NSXPCConnection {
    if let connection {
      return connection
    }
    let created = NSXPCConnection(serviceName: serviceName)
    created.remoteObjectInterface = NSXPCInterface(with: ASRServiceXPCProtocol.self)
    created.resume()
    connection = created
    return created
  }

  private static func unwrap<Value: Codable & Equatable & Sendable>(
    _ type: Value.Type,
    from data: Data
  ) throws(ASRServiceCallFailure) -> Value {
    let reply: ASRServiceReply<Value>
    do {
      reply = try ASRServiceCodec.decode(ASRServiceReply<Value>.self, from: data)
    } catch {
      throw .service(error)
    }
    switch reply {
    case .success(let value):
      return value
    case .failure(let failure):
      throw .service(failure)
    }
  }
}

/// XPC may call both the reply and the error handler; only the first wins.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Result<Data, ASRServiceCallFailure>, Never>?

  init(_ continuation: CheckedContinuation<Result<Data, ASRServiceCallFailure>, Never>) {
    self.continuation = continuation
  }

  func resume(_ result: Result<Data, ASRServiceCallFailure>) {
    let pending = lock.withLock {
      defer { continuation = nil }
      return continuation
    }
    pending?.resume(returning: result)
  }
}
