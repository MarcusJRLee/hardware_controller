import Foundation
import HardwareControllerModelDownload
import XCTest

@testable import VoiceInput

final class VoiceInputModelDownloaderTest: XCTestCase {
  func testEveryFailureHasPlainText() {
    let cases: [(ASRModelDownloadError, String)] = [
      (.catalogUnavailable, "This model is unavailable in this build."),
      (
        .transferFailed("Offline."),
        "The download stopped. Offline. Check the connection and try again."
      ),
      (
        .integrityMismatch("model.gguf"),
        "model.gguf did not match its pinned checksum, so nothing was installed."
      ),
      (.installFailed("Full."), "The model could not be installed. Full."),
      (.cancelled, "The download was cancelled."),
    ]
    for (error, message) in cases {
      XCTAssertEqual(VoiceInputModelDownloader.message(for: error), message)
    }
  }

  /// A failed download leaves no staging bytes behind.
  func testFailureRemovesStaging() async throws {
    let library = try await ModelLibraryFixture()
    let staging = library.root.appendingPathComponent("downloads")
    let downloader = VoiceInputModelDownloader(
      stagingRoot: staging,
      manager: library.registry,
      fetcher: OfflineFetcher()
    )
    let entry = try XCTUnwrap(ASRModelCatalog.whisperBaseEnglish)

    do {
      _ = try await downloader.download(entry) { _ in }
      XCTFail("An offline fetch must fail.")
    } catch let error as ASRModelDownloadError {
      XCTAssertEqual(error, .transferFailed("Offline."))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
  }
}

private struct OfflineFetcher: ASRModelFileFetching {
  func fetch(
    _: URL,
    to _: URL,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws(ASRModelDownloadError) {
    throw .transferFailed("Offline.")
  }
}
