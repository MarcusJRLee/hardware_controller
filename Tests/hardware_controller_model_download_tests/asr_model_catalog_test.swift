import Foundation
import Testing

@testable import HardwareControllerModelDownload

struct ASRModelCatalogTest {
  private static let entries = [
    ASRModelCatalog.parakeetV3, ASRModelCatalog.whisperBaseEnglish,
    ASRModelCatalog.whisperSmallEnglish,
  ]

  @Test
  func everyEntryResolves() {
    #expect(Self.entries.allSatisfy { $0 != nil })
  }

  /// Every file is HTTPS, pinned to an immutable 40-hex commit, and digested.
  @Test(arguments: entries.compactMap { $0 })
  func entryIsFullyPinned(_ entry: ASRModelCatalogEntry) throws {
    let commit = try Regex("/resolve/[0-9a-f]{40}/")
    let digest = try Regex("^[0-9a-f]{64}$")
    for file in entry.files {
      #expect(file.url.scheme == "https", "\(file.name)")
      #expect(file.url.absoluteString.contains(commit), "\(file.name)")
      #expect(file.sha256.wholeMatch(of: digest) != nil, "\(file.name)")
      #expect(file.bytes > 0, "\(file.name)")
    }
    #expect(entry.files.compactMap(\.role).sorted() == ["model", "speech_detection"])
    #expect(Set(entry.files.map(\.name)).count == entry.files.count)
  }

  @Test
  func voiceInputOffersDistinctPackagesSmallestFirst() {
    let downloads = ASRModelCatalog.voiceInputDownloads
    #expect(downloads.count == 3)
    #expect(Set(downloads.map(\.packageID)).count == downloads.count)
    #expect(downloads.map(\.downloadBytes) == downloads.map(\.downloadBytes).sorted())
    #expect(downloads.last?.packageID == "com.longdevity.asr.parakeet_tdt_v3")
  }
}
