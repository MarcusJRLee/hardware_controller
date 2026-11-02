import Foundation
import Testing

@testable import HardwareControllerMac

struct ASRModelPackageStoreTest {
  @Test
  func rejectsPackagesForOtherRuntimes() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "asr_store_\(UUID().uuidString)")
    let store = ASRModelPackageStore(root: root)
    defer { try? store.removeAll() }
    let source = root.appending(path: "source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    #expect(throws: ASRModelPackageStoreError.invalidPackage) {
      try store.install(movingFrom: source)
    }
    #expect(store.installed() == nil)
  }

  @Test
  func recordsNameOnlyStoreDirectories() {
    #expect(ASRModelPackageStore.isSafeDirectoryName("package_abc"))
    #expect(!ASRModelPackageStore.isSafeDirectoryName("../package_abc"))
    #expect(!ASRModelPackageStore.isSafeDirectoryName("other"))
  }
}
