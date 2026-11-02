import Foundation
import Testing

@testable import HardwareControllerModelDownload

struct ASRModelFileFetcherTest {
  /// Plain HTTP is refused before any connection is opened.
  @Test
  func refusesPlainHTTP() async throws {
    let url = try #require(URL(string: "http://example.invalid/model.gguf"))
    let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    await #expect(throws: ASRModelDownloadError.transferFailed("Model downloads must use HTTPS.")) {
      try await URLSessionModelFileFetcher().fetch(url, to: destination) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }
}
