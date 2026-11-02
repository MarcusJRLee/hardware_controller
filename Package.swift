// swift-tools-version: 6.1

import Foundation
import PackageDescription

let repositoryDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().path
let voiceFFILibrary = "\(repositoryDirectory)/target/release/libvoice_ffi.a"
// `scripts/fetch_asr_runtime.sh` verifies and unpacks the pinned runtime here.
let asrRuntimeFrameworks =
  "\(repositoryDirectory)/.build/asr_runtime/TranscribeCpp.xcframework/macos-arm64_x86_64"

let package = Package(
  name: "HardwareController",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(
      name: "HardwareControllerCore",
      targets: ["HardwareControllerCore"]
    ),
    .library(
      name: "HardwareControllerMac",
      targets: ["HardwareControllerMac"]
    ),
    .library(
      name: "HardwareControllerVoiceFFI",
      targets: ["HardwareControllerVoiceFFI"]
    ),
    .executable(
      name: "HardwareController",
      targets: ["HardwareControllerApp"]
    ),
    .executable(
      name: "HardwareControllerASRService",
      targets: ["HardwareControllerASRService"]
    ),
  ],
  targets: [
    .target(
      name: "HardwareControllerCore"
    ),
    .target(
      name: "HardwareControllerAudioBoundary",
      path: "Sources/HardwareControllerAudioBoundary",
      publicHeadersPath: "include",
      linkerSettings: [
        .linkedFramework("AVFAudio")
      ]
    ),
    .target(
      name: "VoiceFFIBridge",
      path: "Sources/voice_ffi_bridge",
      publicHeadersPath: "include",
      linkerSettings: [
        .unsafeFlags([voiceFFILibrary])
      ]
    ),
    .target(
      name: "HardwareControllerVoiceFFI",
      dependencies: ["HardwareControllerCore", "VoiceFFIBridge"],
      path: "Sources/hardware_controller_voice_ffi"
    ),
    // Only the ASR service links transcribe.cpp; the app never loads ggml.
    .target(
      name: "VoiceASRBridge",
      path: "Sources/voice_asr_bridge",
      publicHeadersPath: "include",
      cSettings: [
        .unsafeFlags(["-F", asrRuntimeFrameworks])
      ],
      linkerSettings: [
        .unsafeFlags([
          "-F", asrRuntimeFrameworks,
          "-framework", "CTranscribe",
          // Development and test binaries load the fetched framework in place;
          // `scripts/build_app.sh` replaces this with the bundled location.
          "-Xlinker", "-rpath", "-Xlinker", asrRuntimeFrameworks,
        ])
      ]
    ),
    .target(
      name: "VoiceASRRuntime",
      dependencies: ["VoiceASRBridge"],
      path: "Sources/voice_asr_runtime"
    ),
    .target(
      name: "HardwareControllerASRProtocol",
      path: "Sources/hardware_controller_asr_protocol"
    ),
    .target(
      name: "HardwareControllerASRServiceKit",
      dependencies: [
        "HardwareControllerASRProtocol",
        "HardwareControllerVoiceFFI",
        "VoiceASRRuntime",
      ],
      path: "Sources/hardware_controller_asr_service_kit"
    ),
    .executableTarget(
      name: "HardwareControllerASRService",
      dependencies: ["HardwareControllerASRServiceKit"],
      path: "Sources/hardware_controller_asr_service"
    ),
    .target(
      name: "HardwareControllerModelDownload",
      path: "Sources/hardware_controller_model_download"
    ),
    .target(
      name: "HardwareControllerMac",
      dependencies: [
        "HardwareControllerASRProtocol",
        "HardwareControllerAudioBoundary",
        "HardwareControllerCore",
        "HardwareControllerModelDownload",
        "HardwareControllerVoiceFFI",
      ],
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("IOKit"),
        .linkedFramework("Speech"),
        .linkedLibrary("sqlite3"),
      ]
    ),
    .executableTarget(
      name: "HardwareControllerApp",
      dependencies: [
        "HardwareControllerCore",
        "HardwareControllerMac",
        "HardwareControllerModelDownload",
      ]
    ),
    .testTarget(
      name: "HardwareControllerAudioBoundaryTests",
      dependencies: [
        "HardwareControllerAudioBoundary"
      ]
    ),
    .testTarget(
      name: "HardwareControllerCoreTests",
      dependencies: ["HardwareControllerCore"]
    ),
    .testTarget(
      name: "HardwareControllerVoiceFFITests",
      dependencies: ["HardwareControllerCore", "HardwareControllerVoiceFFI"],
      path: "Tests/hardware_controller_voice_ffi_tests"
    ),
    .testTarget(
      name: "HardwareControllerMacTests",
      dependencies: [
        "HardwareControllerCore",
        "HardwareControllerMac",
        "HardwareControllerModelDownload",
        "HardwareControllerVoiceFFI",
      ]
    ),
    .testTarget(
      name: "VoiceASRRuntimeTests",
      dependencies: ["VoiceASRRuntime"],
      path: "Tests/voice_asr_runtime_tests"
    ),
    .testTarget(
      name: "HardwareControllerASRProtocolTests",
      dependencies: ["HardwareControllerASRProtocol"],
      path: "Tests/hardware_controller_asr_protocol_tests"
    ),
    .testTarget(
      name: "HardwareControllerASRServiceKitTests",
      dependencies: [
        "HardwareControllerASRProtocol",
        "HardwareControllerASRServiceKit",
        "HardwareControllerVoiceFFI",
        "VoiceASRRuntime",
      ],
      path: "Tests/hardware_controller_asr_service_kit_tests"
    ),
    .testTarget(
      name: "HardwareControllerAppTests",
      dependencies: [
        "HardwareControllerApp",
        "HardwareControllerCore",
        "HardwareControllerModelDownload",
      ]
    ),
    .testTarget(
      name: "HardwareControllerModelDownloadTests",
      dependencies: ["HardwareControllerModelDownload"],
      path: "Tests/hardware_controller_model_download_tests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
