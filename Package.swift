// swift-tools-version: 6.1

import Foundation
import PackageDescription

let repositoryDirectory = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().path
let voiceFFILibrary = "\(repositoryDirectory)/target/release/libvoice_ffi.a"

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
      dependencies: ["VoiceFFIBridge"],
      path: "Sources/hardware_controller_voice_ffi"
    ),
    .target(
      name: "HardwareControllerMac",
      dependencies: [
        "HardwareControllerAudioBoundary",
        "HardwareControllerCore",
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
      dependencies: ["HardwareControllerVoiceFFI"],
      path: "Tests/hardware_controller_voice_ffi_tests"
    ),
    .testTarget(
      name: "HardwareControllerMacTests",
      dependencies: [
        "HardwareControllerCore",
        "HardwareControllerMac",
        "HardwareControllerVoiceFFI",
      ]
    ),
    .testTarget(
      name: "HardwareControllerAppTests",
      dependencies: [
        "HardwareControllerApp",
        "HardwareControllerCore",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
