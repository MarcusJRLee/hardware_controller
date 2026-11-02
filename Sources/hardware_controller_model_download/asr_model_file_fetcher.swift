import Foundation

public enum ASRModelDownloadError: Error, Equatable, Sendable {
  case catalogUnavailable
  case transferFailed(String)
  /// A file's size or digest differed from its pin; nothing was installed.
  case integrityMismatch(String)
  case installFailed(String)
  case cancelled
}

/// Fetches one URL to a local file: the only network code in Voice Input and,
/// besides Ollama, in the Mac app.
public protocol ASRModelFileFetching: Sendable {
  func fetch(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws(ASRModelDownloadError)
}

/// Downloads over HTTPS with no cookies, cache, or credentials.
public struct URLSessionModelFileFetcher: ASRModelFileFetching {
  public init() {}

  public func fetch(
    _ url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws(ASRModelDownloadError) {
    guard url.scheme == "https" else {
      throw .transferFailed("Model downloads must use HTTPS.")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(
      configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    do {
      let (bytes, response) = try await session.bytes(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw ASRModelDownloadError.transferFailed("The model server refused the download.")
      }
      FileManager.default.createFile(atPath: destination.path, contents: nil)
      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      var buffer = Data()
      buffer.reserveCapacity(1 << 20)
      var written: Int64 = 0
      for try await byte in bytes {
        buffer.append(byte)
        if buffer.count >= 1 << 20 {
          try handle.write(contentsOf: buffer)
          written += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)
          progress(written)
        }
      }
      try handle.write(contentsOf: buffer)
      progress(written + Int64(buffer.count))
    } catch is CancellationError {
      throw .cancelled
    } catch let error as ASRModelDownloadError {
      throw error
    } catch {
      throw .transferFailed(error.localizedDescription)
    }
  }
}

/// Refuses any redirect that leaves HTTPS.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    request.url?.scheme == "https" ? request : nil
  }
}
