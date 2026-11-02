import Foundation
import HardwareControllerModelDownload

/// One row of the Speech model list: the built-in model, each download the
/// catalog offers, then anything imported. Pure, so every state is tested.
struct VoiceInputModelChoice: Equatable, Identifiable, Sendable {
  enum State: Equatable, Sendable {
    case active
    case installed(VoiceInputInstalledModelPackage)
    case downloading(ASRModelCatalogEntry, fraction: Double)
    case available(ASRModelCatalogEntry)
  }

  let id: String
  let title: String
  let summary: String
  let bytes: Int64
  let state: State
  /// The installed copy, which the user may remove.
  let installed: VoiceInputInstalledModelPackage?

  static func choices(
    installed: [VoiceInputInstalledModelPackage],
    active: VoiceInputInstalledModelPackage?,
    catalog: [ASRModelCatalogEntry],
    downloads: [String: Double]
  ) -> [Self] {
    let compatible = installed.filter { VoiceInputASRModelRegistry.isCompatible($0.package) }
    var rows: [Self] = []
    var listed = Set<String>()

    func row(for package: VoiceInputInstalledModelPackage) -> Self {
      listed.insert(package.package.packageID)
      return Self(
        id: package.package.packageID,
        title: package.package.displayName,
        summary: summary(
          for: package.package.packageID, publisherVerified: package.publisherVerified),
        bytes: Int64(clamping: package.package.verifiedBytes),
        state: package == active ? .active : .installed(package),
        installed: package
      )
    }

    if let builtIn = compatible.first(where: { $0.package.packageID == builtInPackageID }) {
      rows.append(row(for: builtIn))
    }
    for entry in catalog {
      if let package = compatible.first(where: { $0.package.packageID == entry.packageID }) {
        rows.append(row(for: package))
        continue
      }
      listed.insert(entry.packageID)
      rows.append(
        Self(
          id: entry.packageID,
          title: entry.displayName,
          summary: summary(for: entry.packageID, publisherVerified: true),
          bytes: entry.downloadBytes,
          state: downloads[entry.packageID].map { .downloading(entry, fraction: $0) }
            ?? .available(entry),
          installed: nil
        )
      )
    }
    for package in compatible where !listed.contains(package.package.packageID) {
      rows.append(row(for: package))
    }
    return rows
  }

  static let builtInPackageID = "com.longdevity.asr.whisper_tiny_en"

  private static func summary(for packageID: String, publisherVerified: Bool) -> String {
    switch packageID {
    case builtInPackageID: "Built in · fastest · English"
    case "com.longdevity.asr.whisper_base_en": "Faster than Small, more accurate than Tiny"
    case "com.longdevity.asr.whisper_small_en": "More accurate · English"
    case "com.longdevity.asr.parakeet_tdt_v3": "Most accurate · 25 languages · same as the Mac"
    default: publisherVerified ? "Verified" : "Imported from Files"
    }
  }
}
