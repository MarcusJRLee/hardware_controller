import Foundation

/// One pinned file the downloader fetches and verifies.
public struct ASRModelCatalogFile: Equatable, Sendable {
  public let name: String
  public let url: URL
  public let sha256: String
  public let bytes: Int64
  /// The manifest role, or nil for license text folded into the notice.
  public let role: String?

  public init(name: String, url: URL, sha256: String, bytes: Int64, role: String?) {
    self.name = name
    self.url = url
    self.sha256 = sha256
    self.bytes = bytes
    self.role = role
  }
}

/// A pinned transcribe.cpp Model package either app offers to download.
public struct ASRModelCatalogEntry: Equatable, Sendable {
  public let packageID: String
  public let version: String
  public let displayName: String
  public let languages: [String]
  public let spdxExpression: String
  public let sourceURL: URL
  public let minimumMemoryBytes: Int64
  public let recommendedMemoryBytes: Int64
  public let files: [ASRModelCatalogFile]

  public init(
    packageID: String,
    version: String,
    displayName: String,
    languages: [String],
    spdxExpression: String,
    sourceURL: URL,
    minimumMemoryBytes: Int64,
    recommendedMemoryBytes: Int64,
    files: [ASRModelCatalogFile]
  ) {
    self.packageID = packageID
    self.version = version
    self.displayName = displayName
    self.languages = languages
    self.spdxExpression = spdxExpression
    self.sourceURL = sourceURL
    self.minimumMemoryBytes = minimumMemoryBytes
    self.recommendedMemoryBytes = recommendedMemoryBytes
    self.files = files
  }

  public var downloadBytes: Int64 {
    files.reduce(0) { $0 + $1.bytes }
  }
}

public enum ASRModelCatalog {
  // Revisions are immutable Hugging Face commits; digests are verified before
  // any file reaches the Rust validator. Updating a pin is a reviewed change.
  private static let hub = "https://huggingface.co/handy-computer"

  private static func revision(_ repository: String, _ commit: String) -> URL? {
    URL(string: "\(hub)/\(repository)/resolve/\(commit)")
  }

  /// Silero VAD v6.2, shared by every package.
  private static func speechFiles() -> [ASRModelCatalogFile]? {
    guard
      let speech = revision("silero-vad-v6.2-gguf", "a9b2d61c20ae4ddf3644edb34969e8185a485448")
    else {
      return nil
    }
    return [
      ASRModelCatalogFile(
        name: "silero-vad-v6.2-F32.gguf",
        url: speech.appending(path: "silero-vad-v6.2-F32.gguf"),
        sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6",
        bytes: 1_241_056,
        role: "speech_detection"
      ),
      ASRModelCatalogFile(
        name: "silero-LICENSE.txt",
        url: speech.appending(path: "LICENSE"),
        sha256: "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b",
        bytes: 1_075,
        role: nil
      ),
      ASRModelCatalogFile(
        name: "silero-NOTICE.txt",
        url: speech.appending(path: "NOTICE"),
        sha256: "f1ea43096a23b40d4b14fcf131586710035444e69e35051c5d83c60725b50555",
        bytes: 293,
        role: nil
      ),
    ]
  }

  /// One converted Whisper English model at Q8_0 plus its Apache-2.0 texts.
  private static func whisperEnglish(
    size: String,
    displayName: String,
    commit: String,
    model: (sha256: String, bytes: Int64),
    notice: (sha256: String, bytes: Int64),
    memory: (minimum: Int64, recommended: Int64)
  ) -> ASRModelCatalogEntry? {
    let repository = "whisper-\(size).en-gguf"
    guard let root = revision(repository, commit), let speech = speechFiles() else {
      return nil
    }
    let modelName = "whisper-\(size).en-Q8_0.gguf"
    return ASRModelCatalogEntry(
      packageID: "com.longdevity.asr.whisper_\(size)_en",
      version: "\(commit.prefix(7))-q8_0",
      displayName: displayName,
      languages: ["en-US"],
      spdxExpression: "Apache-2.0 AND MIT",
      sourceURL: root.deletingLastPathComponent().deletingLastPathComponent(),
      minimumMemoryBytes: memory.minimum,
      recommendedMemoryBytes: memory.recommended,
      files: [
        ASRModelCatalogFile(
          name: modelName,
          url: root.appending(path: modelName),
          sha256: model.sha256,
          bytes: model.bytes,
          role: "model"
        ),
        ASRModelCatalogFile(
          name: "whisper-LICENSE.txt",
          url: root.appending(path: "LICENSE"),
          sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
          bytes: 11_358,
          role: nil
        ),
        ASRModelCatalogFile(
          name: "whisper-NOTICE.txt",
          url: root.appending(path: "NOTICE"),
          sha256: notice.sha256,
          bytes: notice.bytes,
          role: nil
        ),
      ] + speech
    )
  }

  /// Parakeet TDT 0.6B v3 Q8_0 with Silero speech detection.
  public static let parakeetV3: ASRModelCatalogEntry? = {
    guard
      let parakeet = revision(
        "parakeet-tdt-0.6b-v3-gguf", "d8d8c32cb2017c57e5307767343e97870f8a7f53"),
      let speech = speechFiles()
    else {
      return nil
    }
    return ASRModelCatalogEntry(
      packageID: "com.longdevity.asr.parakeet_tdt_v3",
      version: "d8d8c32-q8_0",
      displayName: "Parakeet TDT 0.6B v3",
      // The 25 European languages Parakeet v3 was trained on.
      languages: [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
      ],
      spdxExpression: "CC-BY-4.0 AND MIT",
      sourceURL: parakeet.deletingLastPathComponent().deletingLastPathComponent(),
      minimumMemoryBytes: 1_073_741_824,
      recommendedMemoryBytes: 2_147_483_648,
      files: [
        ASRModelCatalogFile(
          name: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
          url: parakeet.appending(path: "parakeet-tdt-0.6b-v3-Q8_0.gguf"),
          sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
          bytes: 739_508_576,
          role: "model"
        ),
        speech[0],
        ASRModelCatalogFile(
          name: "parakeet-LICENSE.txt",
          url: parakeet.appending(path: "LICENSE"),
          sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411",
          bytes: 18_657,
          role: nil
        ),
        ASRModelCatalogFile(
          name: "parakeet-NOTICE.txt",
          url: parakeet.appending(path: "NOTICE"),
          sha256: "6f02c515f3deed71bb0e8909c8d8449faeb365ae507f67cd026c677b1bddcec8",
          bytes: 400,
          role: nil
        ),
      ] + speech.dropFirst()
    )
  }()

  public static let whisperBaseEnglish = whisperEnglish(
    size: "base",
    displayName: "Whisper Base English",
    commit: "0dd374130837de419035c77d76440aad61ca135c",
    model: ("3b46ca40bccbf7609c68d88a36d96077a04ca7c87f2060ede06f129fac3e7652", 84_886_208),
    notice: ("96e56d6de15361b9728e8463d8d5571717b86c29a338839a9cb7a9c1b58c81fd", 395),
    memory: (268_435_456, 536_870_912)
  )

  public static let whisperSmallEnglish = whisperEnglish(
    size: "small",
    displayName: "Whisper Small English",
    commit: "ab86448a84fcc15a96a9a2216d93a8dac8427da3",
    model: ("9614e6b7fda2d26018e4f268aece8ca25a83296ea0b534169a585b740bfd71ef", 269_674_144),
    notice: ("9ea2fa3f2d7b6b8b5f672b4a3491eb938d3d7ba033e06b6b02c2b8c6df7d30d8", 396),
    memory: (536_870_912, 1_073_741_824)
  )

  /// Downloads Voice Input offers beside its bundled Whisper Tiny English,
  /// smallest first.
  public static let voiceInputDownloads: [ASRModelCatalogEntry] = [
    whisperBaseEnglish, whisperSmallEnglish, parakeetV3,
  ].compactMap { $0 }
}
